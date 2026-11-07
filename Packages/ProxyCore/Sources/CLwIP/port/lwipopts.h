#ifndef PASSAGE_LWIPOPTS_H
#define PASSAGE_LWIPOPTS_H

/* Single-threaded, no OS: every lwIP call happens on one serial queue. */
#define NO_SYS                      1
#define LWIP_TIMERS                 1
#define SYS_LIGHTWEIGHT_PROT        0
#define LWIP_SOCKET                 0
#define LWIP_NETCONN                0

/* Memory: use libc malloc so the budget is governed by TCP windows below. */
#define MEM_LIBC_MALLOC             1
#define MEMP_MEM_MALLOC             1
#define MEM_ALIGNMENT               8

/* Protocols. UDP/ICMP replies are built in Swift, lwIP only does TCP. */
#define LWIP_IPV4                   1
#define LWIP_IPV6                   1
#define LWIP_TCP                    1
#define LWIP_UDP                    0
#define LWIP_RAW                    0
#define LWIP_ICMP                   0
#define LWIP_ICMP6                  1
#define LWIP_ARP                    0
#define LWIP_ETHERNET               0
#define LWIP_DHCP                   0
#define LWIP_AUTOIP                 0
#define LWIP_ACD                    0
#define LWIP_IGMP                   0
#define LWIP_DNS                    0
#define LWIP_IPV6_MLD               0
#define LWIP_IPV6_AUTOCONFIG        0
#define LWIP_IPV6_DHCP6             0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT 0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS 0
#define LWIP_ND6_QUEUEING           0
#define LWIP_IPV6_FRAG              0
#define LWIP_IPV6_REASS             1
#define IPV6_FRAG_COPYHEADER        1  /* required on 64-bit: pointers do not fit in the fragment header */
#define IP_REASSEMBLY               1
#define IP_FRAG                     0
#define IP_FORWARD                  0
#define LWIP_HAVE_LOOPIF            0
#define LWIP_NETIF_LOOPBACK         0
#define LWIP_SINGLE_NETIF           1

/* TCP tuning: tunnel MTU 1500, IPv6 header 40 + TCP 20 + options. */
#define TCP_MSS                     1400
#define LWIP_WND_SCALE              1
#define TCP_RCV_SCALE               2
#define TCP_WND                     (128 * 1024)
#define TCP_SND_BUF                 (128 * 1024)
#define TCP_SND_QUEUELEN            ((4 * TCP_SND_BUF) / TCP_MSS)
#define TCP_SNDLOWAT                (4 * TCP_MSS)
#define TCP_SNDQUEUELOWAT           (TCP_SND_QUEUELEN / 2)
#define TCP_QUEUE_OOSEQ             1
#define TCP_OVERSIZE                TCP_MSS
#define MEMP_NUM_TCP_PCB            1024
#define MEMP_NUM_TCP_PCB_LISTEN     1
#define TCP_LISTEN_BACKLOG          0
#define LWIP_TCP_KEEPALIVE          0
#define LWIP_CALLBACK_API           1

/* The OS already validated packets it handed us. */
#define CHECKSUM_CHECK_IP           0
#define CHECKSUM_CHECK_TCP          0

#define LWIP_STATS                  0
#define LWIP_NETIF_STATUS_CALLBACK  0
#define LWIP_NETIF_LINK_CALLBACK    0
#define LWIP_ERRNO_STDINCLUDE       1

#endif
