// SPDX-License-Identifier: GPL-2.0
/*
 * Ethernet driver for the legend64 SoC's descriptor-ring MAC (RTL: fpga/rtl/legend_eth.sv).
 *
 * The MAC moves frames by DMA through a coherent port on the CPU's own cache, so buffers
 * need no cache maintenance and received data is already cached when the stack reads it.
 * Receive buffers are page fragments handed to the stack with build_skb(): no copy.
 *
 * Hardware contract:
 *   - two rings of 16-byte descriptors { u64 addr; u32 len; u32 flags }, in normal memory
 *   - receive: addr is 8-byte aligned, the frame is stored at addr + 2 (so the IP header is
 *     4-byte aligned), then len and DONE are written and RX_HEAD advances; the hardware
 *     fills descriptors up to, not including, RX_TAIL
 *   - transmit: addr is any byte address, len bytes are sent (the MAC pads and adds the
 *     FCS), then DONE is written and TX_HEAD advances; descriptors up to, not including,
 *     TX_TAIL are sent
 *   - interrupt status bits are sticky and the interrupt line is status & enable
 *
 * Offloads, where the FEATURES register announces them:
 *   - receive: the descriptor carries the ones' complement sum of the frame after the
 *     Ethernet header (CHECKSUM_COMPLETE), so neither GRO nor TCP reads the data to check it
 *   - transmit: a frame may be the bytes of several descriptors (flag MORE), so fragments
 *     go out where they lie, and the hardware fills in a checksum given where to start
 *     summing and where to store the result (the stack's CHECKSUM_PARTIAL)
 *   - TCP segmentation rests on those two: the driver writes each segment's headers into
 *     its own small buffer (net/core/tso.c) and points descriptors at the payload in
 *     place; the hardware assembles and checksums each segment.
 */
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/of.h>
#include <linux/of_net.h>
#include <linux/platform_device.h>
#include <linux/skbuff.h>
#include <linux/tcp.h>
#include <net/ip.h>
#include <net/ip6_checksum.h>
#include <net/tso.h>

#define FE_CTRL		0x00
#define  FE_CTRL_RX_EN		BIT(0)
#define  FE_CTRL_TX_EN		BIT(1)
#define  FE_CTRL_PROMISC	BIT(2)
#define  FE_CTRL_RING_RESET	BIT(8)
#define FE_STATUS	0x04
#define  FE_STATUS_LINK		BIT(0)
#define FE_IRQ_STATUS	0x08
#define FE_IRQ_ENABLE	0x0c
#define  FE_IRQ_RX		BIT(0)
#define  FE_IRQ_TX		BIT(1)
#define  FE_IRQ_DROP		BIT(2)
#define  FE_IRQ_ALL		(FE_IRQ_RX | FE_IRQ_TX | FE_IRQ_DROP)
#define FE_MAC_LO	0x10
#define FE_MAC_HI	0x14
#define FE_RX_BASE_LO	0x20
#define FE_RX_BASE_HI	0x24
#define FE_RX_SIZE	0x28
#define FE_RX_HEAD	0x2c
#define FE_RX_TAIL	0x30
#define FE_TX_BASE_LO	0x40
#define FE_TX_BASE_HI	0x44
#define FE_TX_SIZE	0x48
#define FE_TX_HEAD	0x4c
#define FE_TX_TAIL	0x50
#define FE_RX_DROPPED	0x60
#define FE_FEATURES	0x64
#define  FE_FEAT_RX_CSUM	BIT(0)
#define  FE_FEAT_TX_SG		BIT(1)
#define  FE_FEAT_TX_CSUM	BIT(2)
#define  FE_FEAT_COUNTERS	BIT(3)
#define FE_RX_FIFO	0x68		/* 16-bit counts of frames lost in the hardware: FIFO full, */
#define FE_RX_BAD	0x6c		/* marked bad by the MAC, */
#define FE_RX_LONG	0x70		/* longer than 1518 bytes */
#define  FE_FEAT_TX_COUNTERS	BIT(4)
#define FE_TX_QUEUED	0x74		/* 16-bit counts of transmit frames: put into the FIFO, */
#define FE_TX_DISCARD	0x78		/* given up by the hardware, */
#define FE_TX_MAC	0x7c		/* taken by the MAC, */
#define FE_TX_PCS	0x80		/* started on the MAC's output */

#define FE_DESC_DONE	BIT(0)
#define FE_RXD_CSUM	BIT(1)		/* bits 31:16 hold the sum */
#define FE_TXD_MORE	BIT(1)		/* the frame continues in the next descriptor */
#define FE_TXD_CSUM	BIT(2)		/* first descriptor of a frame: insert a checksum */
#define FE_TXD_CSUM_START(x)	((u32)(x) << 16)	/* sum from this byte of the frame (even, < 256) */
#define FE_TXD_CSUM_OFFSET(x)	((u32)(x) << 24)	/* store that far beyond it (even, < 256) */
#define FE_CSUM_LIMIT	254

#define FE_RX_RING	256		/* powers of two */
#define FE_TX_RING	256
#define FE_TSO_MAX_SEGS	48
/* most descriptors one packet can need: a header and a payload piece per segment, plus fragments */
#define FE_TX_MAX_DESC	(2 * FE_TSO_MAX_SEGS + MAX_SKB_FRAGS + 1)
#define FE_RX_OFFSET	2		/* where the hardware starts the frame */
#define FE_RX_DATA	1536		/* what the hardware may write */
#define FE_MAX_FRAME	1518
#define FE_BUF_SIZE	(SKB_DATA_ALIGN(NET_SKB_PAD + FE_RX_DATA) + \
			 SKB_DATA_ALIGN(sizeof(struct skb_shared_info)))

struct fe_desc {
	__le64 addr;
	__le32 len;
	__le32 flags;
};

enum fe_tx_map { FE_MAP_NONE, FE_MAP_SINGLE, FE_MAP_PAGE };

struct fe_tx_buf {
	struct sk_buff *skb;		/* on a packet's last descriptor only */
	dma_addr_t dma;
	u32 len;
	enum fe_tx_map map;
};

struct fe_priv {
	void __iomem *regs;
	struct net_device *ndev;
	struct device *dev;
	struct napi_struct napi;
	struct timer_list link_timer;

	struct fe_desc *rx_ring, *tx_ring;
	dma_addr_t rx_ring_dma, tx_ring_dma;
	void *rx_buf[FE_RX_RING];
	dma_addr_t rx_dma[FE_RX_RING];
	struct fe_tx_buf tx_buf[FE_TX_RING];
	char *tso_hdrs;			/* TSO_HEADER_SIZE bytes per transmit descriptor */
	dma_addr_t tso_hdrs_dma;
	unsigned int rx_cur;		/* next descriptor to look at */
	unsigned int rx_tail;		/* limit given to the hardware */
	unsigned int tx_head;		/* next descriptor to fill */
	unsigned int tx_clean;		/* oldest descriptor not yet reclaimed */
	u32 ctrl;
	u32 hw_feat;
	u16 cnt_fifo, cnt_bad, cnt_long;	/* last readings */
};

static inline u32 fe_rd(struct fe_priv *p, unsigned int reg)
{
	return readl(p->regs + reg);
}

static inline void fe_wr(struct fe_priv *p, unsigned int reg, u32 val)
{
	writel(val, p->regs + reg);
}

static int fe_rx_alloc(struct fe_priv *p, unsigned int i)
{
	void *buf = netdev_alloc_frag(FE_BUF_SIZE);
	dma_addr_t dma;

	if (!buf)
		return -ENOMEM;
	/* NET_SKB_PAD is a multiple of the cache line, so the address is 8-byte aligned */
	dma = dma_map_single(p->dev, buf + NET_SKB_PAD, FE_RX_DATA, DMA_FROM_DEVICE);
	if (dma_mapping_error(p->dev, dma)) {
		skb_free_frag(buf);
		return -ENOMEM;
	}
	p->rx_buf[i] = buf;
	p->rx_dma[i] = dma;
	p->rx_ring[i].addr = cpu_to_le64(dma);
	p->rx_ring[i].len = 0;
	p->rx_ring[i].flags = 0;
	return 0;
}

static void fe_set_mac(struct fe_priv *p)
{
	const u8 *a = p->ndev->dev_addr;

	fe_wr(p, FE_MAC_LO, a[0] | a[1] << 8 | a[2] << 16 | (u32)a[3] << 24);
	fe_wr(p, FE_MAC_HI, a[4] | a[5] << 8);
}

static int fe_rx(struct fe_priv *p, int budget)
{
	struct net_device *ndev = p->ndev;
	int done = 0;

	while (done < budget) {
		unsigned int i = p->rx_cur;
		struct fe_desc *d = &p->rx_ring[i];
		void *buf = p->rx_buf[i];
		struct sk_buff *skb;
		u32 len, flags;

		flags = le32_to_cpu(READ_ONCE(d->flags));
		if (!(flags & FE_DESC_DONE))
			break;
		len = le32_to_cpu(d->len);
		dma_unmap_single(p->dev, p->rx_dma[i], FE_RX_DATA, DMA_FROM_DEVICE);

		/* replace the buffer first: if that fails, recycle this one and drop the frame */
		if (fe_rx_alloc(p, i)) {
			p->rx_buf[i] = buf;
			p->rx_dma[i] = dma_map_single(p->dev, buf + NET_SKB_PAD, FE_RX_DATA, DMA_FROM_DEVICE);
			d->addr = cpu_to_le64(p->rx_dma[i]);
			d->flags = 0;
			ndev->stats.rx_dropped++;
		} else if (len < ETH_HLEN || len > FE_RX_DATA - FE_RX_OFFSET) {
			skb_free_frag(buf);
			ndev->stats.rx_errors++;
		} else {
			skb = build_skb(buf, FE_BUF_SIZE);
			if (!skb) {
				skb_free_frag(buf);
				ndev->stats.rx_dropped++;
			} else {
				skb_reserve(skb, NET_SKB_PAD + FE_RX_OFFSET);
				skb_put(skb, len);
				skb->protocol = eth_type_trans(skb, ndev);
				if ((flags & FE_RXD_CSUM) && (ndev->features & NETIF_F_RXCSUM)) {
					/* summed from the end of the Ethernet header, where skb->data now is */
					skb->csum = (__force __wsum)(flags >> 16);
					skb->ip_summed = CHECKSUM_COMPLETE;
				}
				ndev->stats.rx_packets++;
				ndev->stats.rx_bytes += len;
				napi_gro_receive(&p->napi, skb);
			}
		}
		p->rx_cur = (i + 1) & (FE_RX_RING - 1);
		p->rx_tail = (p->rx_tail + 1) & (FE_RX_RING - 1);
		done++;
	}
	if (done)
		fe_wr(p, FE_RX_TAIL, p->rx_tail);
	return done;
}

static unsigned int fe_tx_free(struct fe_priv *p)
{
	return (p->tx_clean - p->tx_head - 1) & (FE_TX_RING - 1);
}

static void fe_tx_unmap(struct fe_priv *p, unsigned int i)
{
	struct fe_tx_buf *b = &p->tx_buf[i];

	if (b->map == FE_MAP_SINGLE)
		dma_unmap_single(p->dev, b->dma, b->len, DMA_TO_DEVICE);
	else if (b->map == FE_MAP_PAGE)
		dma_unmap_page(p->dev, b->dma, b->len, DMA_TO_DEVICE);
	b->map = FE_MAP_NONE;
}

static void fe_tx_clean(struct fe_priv *p)
{
	struct net_device *ndev = p->ndev;
	unsigned int hw = fe_rd(p, FE_TX_HEAD) & (FE_TX_RING - 1);

	while (p->tx_clean != hw) {
		unsigned int i = p->tx_clean;
		struct sk_buff *skb = p->tx_buf[i].skb;

		fe_tx_unmap(p, i);
		if (skb) {
			ndev->stats.tx_packets += skb_shinfo(skb)->gso_segs ?: 1;
			ndev->stats.tx_bytes += skb->len;
			dev_consume_skb_any(skb);
			p->tx_buf[i].skb = NULL;
		}
		p->tx_clean = (i + 1) & (FE_TX_RING - 1);
	}
	if (netif_queue_stopped(ndev) && fe_tx_free(p) >= FE_TX_MAX_DESC)
		netif_wake_queue(ndev);
}

static int fe_poll(struct napi_struct *napi, int budget)
{
	struct fe_priv *p = container_of(napi, struct fe_priv, napi);
	u32 st = fe_rd(p, FE_IRQ_STATUS);
	int done;

	/* acknowledge before looking, so nothing that arrives while we work is lost */
	fe_wr(p, FE_IRQ_STATUS, st);
	if (st & FE_IRQ_DROP)
		p->ndev->stats.rx_missed_errors = fe_rd(p, FE_RX_DROPPED);
	fe_tx_clean(p);
	done = fe_rx(p, budget);
	if (done < budget && napi_complete_done(napi, done))
		fe_wr(p, FE_IRQ_ENABLE, FE_IRQ_ALL);
	return done;
}

static irqreturn_t fe_irq(int irq, void *data)
{
	struct fe_priv *p = data;

	if (!(fe_rd(p, FE_IRQ_STATUS) & FE_IRQ_ALL))
		return IRQ_NONE;
	fe_wr(p, FE_IRQ_ENABLE, 0);
	napi_schedule(&p->napi);
	return IRQ_HANDLED;
}

/* Fill the next descriptor; the hardware does not see it until TX_TAIL moves. */
static void fe_tx_desc(struct fe_priv *p, unsigned int *i, dma_addr_t dma, u32 len, u32 flags,
		       enum fe_tx_map map)
{
	struct fe_tx_buf *b = &p->tx_buf[*i];
	struct fe_desc *d = &p->tx_ring[*i];

	b->skb = NULL;
	b->dma = dma;
	b->len = len;
	b->map = map;
	d->addr = cpu_to_le64(dma);
	d->len = cpu_to_le32(len);
	d->flags = cpu_to_le32(flags);
	*i = (*i + 1) & (FE_TX_RING - 1);
}

/* Give up a packet part of whose descriptors have been filled: nothing was shown to the hardware. */
static netdev_tx_t fe_tx_drop(struct fe_priv *p, struct sk_buff *skb, unsigned int end)
{
	unsigned int i;

	for (i = p->tx_head; i != end; i = (i + 1) & (FE_TX_RING - 1))
		fe_tx_unmap(p, i);
	dev_kfree_skb_any(skb);
	p->ndev->stats.tx_dropped++;
	return NETDEV_TX_OK;
}

static void fe_tx_commit(struct fe_priv *p, struct sk_buff *skb, unsigned int end)
{
	p->tx_buf[(end - 1) & (FE_TX_RING - 1)].skb = skb;
	p->tx_head = end;
	fe_wr(p, FE_TX_TAIL, end);
	if (fe_tx_free(p) < FE_TX_MAX_DESC)
		netif_stop_queue(p->ndev);
}

/*
 * A packet for the stack to have segmented: one frame per segment, made of a header the
 * driver writes and the payload where it is. The hardware completes the TCP checksum, which
 * is left holding the pseudo-header sum; the IP header's is done here.
 */
static netdev_tx_t fe_xmit_tso(struct fe_priv *p, struct sk_buff *skb)
{
	unsigned int i = p->tx_head, l3 = skb_network_offset(skb), l4 = skb_transport_offset(skb);
	int hdr_len, total, mss = skb_shinfo(skb)->gso_size;
	struct tso_t tso;

	hdr_len = tso_start(skb, &tso);
	total = skb->len - hdr_len;
	while (total > 0) {
		char *hdr = p->tso_hdrs + i * TSO_HEADER_SIZE;
		dma_addr_t hdr_dma = p->tso_hdrs_dma + i * TSO_HEADER_SIZE;
		int left = min(mss, total);
		struct tcphdr *th = (struct tcphdr *)(hdr + l4);

		total -= left;
		tso_build_hdr(skb, hdr, &tso, left, total == 0);
		if (tso.ipv6) {
			struct ipv6hdr *ip6 = (struct ipv6hdr *)(hdr + l3);

			th->check = ~csum_ipv6_magic(&ip6->saddr, &ip6->daddr, tso.tlen + left, IPPROTO_TCP, 0);
		} else {
			struct iphdr *ip = (struct iphdr *)(hdr + l3);

			ip->check = 0;
			ip->check = ip_fast_csum(ip, ip->ihl);
			th->check = ~csum_tcpudp_magic(ip->saddr, ip->daddr, tso.tlen + left, IPPROTO_TCP, 0);
		}
		fe_tx_desc(p, &i, hdr_dma, hdr_len,
			   FE_TXD_MORE | FE_TXD_CSUM | FE_TXD_CSUM_START(l4) |
			   FE_TXD_CSUM_OFFSET(offsetof(struct tcphdr, check)), FE_MAP_NONE);
		while (left > 0) {
			int size = min(tso.size, left);
			dma_addr_t dma = dma_map_single(p->dev, tso.data, size, DMA_TO_DEVICE);

			if (dma_mapping_error(p->dev, dma))
				return fe_tx_drop(p, skb, i);
			left -= size;
			fe_tx_desc(p, &i, dma, size, left ? FE_TXD_MORE : 0, FE_MAP_SINGLE);
			tso_build_data(skb, &tso, size);
		}
	}
	fe_tx_commit(p, skb, i);
	return NETDEV_TX_OK;
}

static netdev_tx_t fe_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct fe_priv *p = netdev_priv(ndev);
	unsigned int i = p->tx_head, f, nfrags = skb_shinfo(skb)->nr_frags;
	u32 flags = 0;
	dma_addr_t dma;

	/* the queue is stopped while there is not room for the largest packet */
	if (fe_tx_free(p) < FE_TX_MAX_DESC) {
		netif_stop_queue(ndev);
		return NETDEV_TX_BUSY;
	}
	if (skb_is_gso(skb))
		return fe_xmit_tso(p, skb);
	if (skb->len > FE_MAX_FRAME)
		return fe_tx_drop(p, skb, i);
	if (skb->ip_summed == CHECKSUM_PARTIAL)
		flags = FE_TXD_CSUM | FE_TXD_CSUM_START(skb_checksum_start_offset(skb)) |
			FE_TXD_CSUM_OFFSET(skb->csum_offset);

	dma = dma_map_single(p->dev, skb->data, skb_headlen(skb), DMA_TO_DEVICE);
	if (dma_mapping_error(p->dev, dma))
		return fe_tx_drop(p, skb, i);
	fe_tx_desc(p, &i, dma, skb_headlen(skb), flags | (nfrags ? FE_TXD_MORE : 0), FE_MAP_SINGLE);
	for (f = 0; f < nfrags; f++) {
		const skb_frag_t *frag = &skb_shinfo(skb)->frags[f];

		dma = skb_frag_dma_map(p->dev, frag, 0, skb_frag_size(frag), DMA_TO_DEVICE);
		if (dma_mapping_error(p->dev, dma))
			return fe_tx_drop(p, skb, i);
		fe_tx_desc(p, &i, dma, skb_frag_size(frag), f + 1 < nfrags ? FE_TXD_MORE : 0, FE_MAP_PAGE);
	}
	fe_tx_commit(p, skb, i);
	return NETDEV_TX_OK;
}

/*
 * What the hardware cannot do for a particular packet is left to the stack: a checksum that
 * starts or lies beyond the descriptor's 8-bit fields or at an odd offset, and segmentation
 * when the headers do not fit a header buffer.
 */
static netdev_features_t fe_features_check(struct sk_buff *skb, struct net_device *ndev,
					   netdev_features_t features)
{
	if (skb->ip_summed == CHECKSUM_PARTIAL) {
		unsigned int start = skb_checksum_start_offset(skb);

		if (start > FE_CSUM_LIMIT || (start & 1) ||
		    skb->csum_offset > FE_CSUM_LIMIT || (skb->csum_offset & 1))
			features &= ~(NETIF_F_CSUM_MASK | NETIF_F_GSO_MASK);
	}
	if (skb_is_gso(skb) &&
	    (!skb_is_gso_tcp(skb) || skb_transport_offset(skb) + tcp_hdrlen(skb) > TSO_HEADER_SIZE))
		features &= ~NETIF_F_GSO_MASK;
	return features;
}

/* The hardware's loss counters are 16 bits and wrap: add what each has moved by. */
static void fe_read_counters(struct fe_priv *p)
{
	struct net_device_stats *st = &p->ndev->stats;
	u16 fifo, bad, lng;

	if (!(p->hw_feat & FE_FEAT_COUNTERS))
		return;
	fifo = fe_rd(p, FE_RX_FIFO);
	bad = fe_rd(p, FE_RX_BAD);
	lng = fe_rd(p, FE_RX_LONG);
	st->rx_fifo_errors += (u16)(fifo - p->cnt_fifo);
	st->rx_crc_errors += (u16)(bad - p->cnt_bad);
	st->rx_length_errors += (u16)(lng - p->cnt_long);
	st->rx_errors += (u16)(fifo - p->cnt_fifo) + (u16)(bad - p->cnt_bad) + (u16)(lng - p->cnt_long);
	p->cnt_fifo = fifo;
	p->cnt_bad = bad;
	p->cnt_long = lng;
}

static void fe_link_timer(struct timer_list *t)
{
	struct fe_priv *p = timer_container_of(p, t, link_timer);
	bool up = fe_rd(p, FE_STATUS) & FE_STATUS_LINK;

	fe_read_counters(p);

	if (up != netif_carrier_ok(p->ndev)) {
		if (up)
			netif_carrier_on(p->ndev);
		else
			netif_carrier_off(p->ndev);
		netdev_info(p->ndev, "link %s\n", up ? "up, 1000 Mbit/s full duplex" : "down");
	}
	mod_timer(&p->link_timer, jiffies + HZ);
}

static void fe_free_buffers(struct fe_priv *p)
{
	unsigned int i;

	for (i = 0; i < FE_RX_RING; i++) {
		if (!p->rx_buf[i])
			continue;
		dma_unmap_single(p->dev, p->rx_dma[i], FE_RX_DATA, DMA_FROM_DEVICE);
		skb_free_frag(p->rx_buf[i]);
		p->rx_buf[i] = NULL;
	}
	for (i = 0; i < FE_TX_RING; i++) {
		fe_tx_unmap(p, i);
		if (p->tx_buf[i].skb)
			dev_kfree_skb_any(p->tx_buf[i].skb);
		p->tx_buf[i].skb = NULL;
	}
}

static int fe_open(struct net_device *ndev)
{
	struct fe_priv *p = netdev_priv(ndev);
	unsigned int i;
	int err;

	fe_wr(p, FE_CTRL, FE_CTRL_RING_RESET);
	fe_wr(p, FE_IRQ_ENABLE, 0);
	fe_wr(p, FE_IRQ_STATUS, FE_IRQ_ALL);
	memset(p->tx_ring, 0, FE_TX_RING * sizeof(struct fe_desc));
	for (i = 0; i < FE_RX_RING; i++) {
		err = fe_rx_alloc(p, i);
		if (err) {
			fe_free_buffers(p);
			return err;
		}
	}
	p->rx_cur = 0;
	p->rx_tail = FE_RX_RING - 1;
	p->tx_head = 0;
	p->tx_clean = 0;

	fe_set_mac(p);
	fe_wr(p, FE_RX_BASE_LO, lower_32_bits(p->rx_ring_dma));
	fe_wr(p, FE_RX_BASE_HI, upper_32_bits(p->rx_ring_dma));
	fe_wr(p, FE_RX_SIZE, FE_RX_RING);
	fe_wr(p, FE_TX_BASE_LO, lower_32_bits(p->tx_ring_dma));
	fe_wr(p, FE_TX_BASE_HI, upper_32_bits(p->tx_ring_dma));
	fe_wr(p, FE_TX_SIZE, FE_TX_RING);
	fe_wr(p, FE_RX_TAIL, p->rx_tail);

	napi_enable(&p->napi);
	p->ctrl = FE_CTRL_RX_EN | FE_CTRL_TX_EN | (ndev->flags & IFF_PROMISC ? FE_CTRL_PROMISC : 0);
	fe_wr(p, FE_CTRL, p->ctrl);
	fe_wr(p, FE_IRQ_ENABLE, FE_IRQ_ALL);
	netif_carrier_off(ndev);
	mod_timer(&p->link_timer, jiffies);
	netif_start_queue(ndev);
	return 0;
}

static int fe_stop(struct net_device *ndev)
{
	struct fe_priv *p = netdev_priv(ndev);

	netif_stop_queue(ndev);
	timer_delete_sync(&p->link_timer);
	fe_wr(p, FE_IRQ_ENABLE, 0);
	fe_wr(p, FE_CTRL, 0);
	/* the hardware finishes a frame it has started; give it time before taking the buffers */
	msleep(5);
	napi_disable(&p->napi);
	fe_wr(p, FE_CTRL, FE_CTRL_RING_RESET);
	fe_free_buffers(p);
	netif_carrier_off(ndev);
	return 0;
}

static void fe_set_rx_mode(struct net_device *ndev)
{
	struct fe_priv *p = netdev_priv(ndev);

	/* the hardware accepts all multicast frames; only promiscuous mode needs a setting */
	if (ndev->flags & IFF_PROMISC)
		p->ctrl |= FE_CTRL_PROMISC;
	else
		p->ctrl &= ~FE_CTRL_PROMISC;
	fe_wr(p, FE_CTRL, p->ctrl);
}

static int fe_set_mac_address(struct net_device *ndev, void *addr)
{
	int err = eth_mac_addr(ndev, addr);

	if (!err)
		fe_set_mac(netdev_priv(ndev));
	return err;
}

/*
 * The hardware's 16-bit frame counters as they stand, for finding where frames go missing:
 * read the file before and after a test and subtract (they wrap).
 */
static ssize_t hw_counters_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct fe_priv *p = netdev_priv(dev_get_drvdata(dev));
	int n = 0;

	if (p->hw_feat & FE_FEAT_TX_COUNTERS)
		n += sysfs_emit_at(buf, n, "tx_queued %u\ntx_discarded %u\ntx_mac %u\ntx_pcs %u\n",
				   fe_rd(p, FE_TX_QUEUED), fe_rd(p, FE_TX_DISCARD),
				   fe_rd(p, FE_TX_MAC), fe_rd(p, FE_TX_PCS));
	if (p->hw_feat & FE_FEAT_COUNTERS)
		n += sysfs_emit_at(buf, n, "rx_fifo_full %u\nrx_bad %u\nrx_long %u\n",
				   fe_rd(p, FE_RX_FIFO), fe_rd(p, FE_RX_BAD), fe_rd(p, FE_RX_LONG));
	n += sysfs_emit_at(buf, n, "rx_no_descriptor %u\n", fe_rd(p, FE_RX_DROPPED));
	return n;
}
static DEVICE_ATTR_RO(hw_counters);

static struct attribute *fe_attrs[] = {
	&dev_attr_hw_counters.attr,
	NULL
};
ATTRIBUTE_GROUPS(fe);

static const struct net_device_ops fe_netdev_ops = {
	.ndo_open		= fe_open,
	.ndo_stop		= fe_stop,
	.ndo_start_xmit		= fe_xmit,
	.ndo_features_check	= fe_features_check,
	.ndo_set_rx_mode	= fe_set_rx_mode,
	.ndo_set_mac_address	= fe_set_mac_address,
	.ndo_validate_addr	= eth_validate_addr,
};

static int fe_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct net_device *ndev;
	struct fe_priv *p;
	int irq, err;

	ndev = devm_alloc_etherdev(dev, sizeof(*p));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);
	p = netdev_priv(ndev);
	p->ndev = ndev;
	p->dev = dev;

	p->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->regs))
		return PTR_ERR(p->regs);
	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;

	err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (err)
		return err;
	p->rx_ring = dmam_alloc_coherent(dev, FE_RX_RING * sizeof(struct fe_desc), &p->rx_ring_dma, GFP_KERNEL);
	p->tx_ring = dmam_alloc_coherent(dev, FE_TX_RING * sizeof(struct fe_desc), &p->tx_ring_dma, GFP_KERNEL);
	p->tso_hdrs = dmam_alloc_coherent(dev, FE_TX_RING * TSO_HEADER_SIZE, &p->tso_hdrs_dma, GFP_KERNEL);
	if (!p->rx_ring || !p->tx_ring || !p->tso_hdrs)
		return -ENOMEM;

	fe_wr(p, FE_CTRL, FE_CTRL_RING_RESET);
	fe_wr(p, FE_IRQ_ENABLE, 0);
	err = devm_request_irq(dev, irq, fe_irq, 0, dev_name(dev), p);
	if (err)
		return err;

	err = of_get_ethdev_address(dev->of_node, ndev);
	if (err)
		eth_hw_addr_random(ndev);
	ndev->netdev_ops = &fe_netdev_ops;
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = ETH_DATA_LEN;
	p->hw_feat = fe_rd(p, FE_FEATURES);
	if (p->hw_feat & FE_FEAT_COUNTERS) {
		p->cnt_fifo = fe_rd(p, FE_RX_FIFO);
		p->cnt_bad = fe_rd(p, FE_RX_BAD);
		p->cnt_long = fe_rd(p, FE_RX_LONG);
	}
	if (p->hw_feat & FE_FEAT_RX_CSUM)
		ndev->hw_features |= NETIF_F_RXCSUM;
	if (p->hw_feat & FE_FEAT_TX_SG)
		ndev->hw_features |= NETIF_F_SG;
	if ((p->hw_feat & (FE_FEAT_TX_SG | FE_FEAT_TX_CSUM)) == (FE_FEAT_TX_SG | FE_FEAT_TX_CSUM)) {
		ndev->hw_features |= NETIF_F_HW_CSUM | NETIF_F_TSO | NETIF_F_TSO6;
		netif_set_tso_max_segs(ndev, FE_TSO_MAX_SEGS);
	}
	ndev->features |= ndev->hw_features;
	timer_setup(&p->link_timer, fe_link_timer, 0);
	netif_napi_add(ndev, &p->napi, fe_poll);

	err = devm_register_netdev(dev, ndev);
	if (err)
		return err;
	netdev_info(ndev, "legend64 Ethernet at %pR, irq %d, %pM, offloads:%s%s%s\n",
		    platform_get_resource(pdev, IORESOURCE_MEM, 0), irq, ndev->dev_addr,
		    p->hw_feat & FE_FEAT_RX_CSUM ? " rx-checksum" : "",
		    ndev->hw_features & NETIF_F_TSO ? " tx-checksum sg tso" : "",
		    p->hw_feat ? "" : " none");
	return 0;
}

static const struct of_device_id fe_of_match[] = {
	{ .compatible = "legend,eth" },
	{ }
};
MODULE_DEVICE_TABLE(of, fe_of_match);

static struct platform_driver fe_driver = {
	.probe = fe_probe,
	.driver = {
		.name = "legend-eth",
		.dev_groups = fe_groups,
		.of_match_table = fe_of_match,
	},
};
module_platform_driver(fe_driver);

MODULE_DESCRIPTION("legend64 SoC Ethernet (descriptor rings, cache-coherent DMA)");
MODULE_LICENSE("GPL");
