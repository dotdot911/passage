#include "pslwip.h"

#include <time.h>

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/ip.h"
#include "lwip/ip4_frag.h"
#include "lwip/ip6_frag.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "lwip/priv/tcp_priv.h"

static ps_callbacks g_cb;
static struct netif g_netif;
static struct tcp_pcb *g_listener;
static uint8_t g_out_buf[0xFFFF]; /* pbuf_copy_partial takes a u16_t length */

u32_t sys_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (u32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static err_t emit(struct pbuf *p) {
  u16_t n = pbuf_copy_partial(p, g_out_buf, sizeof(g_out_buf), 0);
  g_cb.output(g_cb.ctx, g_out_buf, n);
  return ERR_OK;
}

static err_t out4(struct netif *n, struct pbuf *p, const ip4_addr_t *a) { (void)n; (void)a; return emit(p); }
static err_t out6(struct netif *n, struct pbuf *p, const ip6_addr_t *a) { (void)n; (void)a; return emit(p); }

static err_t netif_setup(struct netif *n) {
  n->name[0] = 'p'; n->name[1] = 's';
  n->mtu = 1500;
  n->output = out4;
  n->output_ip6 = out6;
  return ERR_OK;
}

static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
  (void)arg; (void)err;
  if (p == NULL) {
    g_cb.recv(g_cb.ctx, pcb, NULL, 0);
    return ERR_OK;
  }
  for (struct pbuf *q = p; q != NULL; q = q->next) {
    if (q->len > 0) g_cb.recv(g_cb.ctx, pcb, (const uint8_t *)q->payload, q->len);
  }
  pbuf_free(p);
  return ERR_OK;
}

static err_t on_sent(void *arg, struct tcp_pcb *pcb, u16_t len) {
  (void)arg;
  g_cb.sent(g_cb.ctx, pcb, len);
  return ERR_OK;
}

static void on_err(void *arg, err_t err) {
  /* lwIP passes the freed pcb as arg because we set tcp_arg(pcb, pcb). */
  g_cb.error(g_cb.ctx, (ps_tcp_t)arg, err);
}

static err_t on_accept(void *arg, struct tcp_pcb *pcb, err_t err) {
  (void)arg;
  if (err != ERR_OK || pcb == NULL) return ERR_VAL;
  tcp_arg(pcb, pcb);
  tcp_recv(pcb, on_recv);
  tcp_sent(pcb, on_sent);
  tcp_err(pcb, on_err);
  tcp_nagle_disable(pcb);
  int v6 = IP_IS_V6(&pcb->local_ip);
  const uint8_t *src = v6 ? (const uint8_t *)ip_2_ip6(&pcb->remote_ip)->addr : (const uint8_t *)&ip_2_ip4(&pcb->remote_ip)->addr;
  const uint8_t *dst = v6 ? (const uint8_t *)ip_2_ip6(&pcb->local_ip)->addr : (const uint8_t *)&ip_2_ip4(&pcb->local_ip)->addr;
  g_cb.accept(g_cb.ctx, pcb, v6, src, pcb->remote_port, dst, pcb->local_port);
  return ERR_OK;
}

void ps_stack_init(ps_callbacks callbacks) {
  g_cb = callbacks;
  lwip_init();
  netif_add_noaddr(&g_netif, NULL, netif_setup, ip_input);
  ip4_addr_t addr, mask, gw;
  IP4_ADDR(&addr, 198, 18, 0, 1);
  IP4_ADDR(&mask, 255, 254, 0, 0);
  IP4_ADDR(&gw, 0, 0, 0, 0);
  netif_set_addr(&g_netif, &addr, &mask, &gw);
  ip6_addr_t a6;
  IP6_ADDR(&a6, PP_HTONL(0xfd005050UL), 0, 0, PP_HTONL(1UL));
  netif_ip6_addr_set(&g_netif, 0, &a6);
  netif_ip6_addr_set_state(&g_netif, 0, IP6_ADDR_VALID);
  netif_set_default(&g_netif);
  netif_set_up(&g_netif);
  netif_set_link_up(&g_netif);

  struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
  tcp_bind(pcb, IP_ANY_TYPE, 1);
  g_listener = tcp_listen(pcb);
  g_listener->local_port = 0; /* patched tcp_in.c: port 0 listens on every port */
  tcp_accept(g_listener, on_accept);
}

int ps_stack_input(const uint8_t *packet, size_t len) {
  if (len == 0 || len > 65535) return -1;
  struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
  if (p == NULL) return -1;
  pbuf_take(p, packet, (u16_t)len);
  if (g_netif.input(p, &g_netif) != ERR_OK) {
    pbuf_free(p);
    return -1;
  }
  return 0;
}

void ps_stack_check_timeouts(void) { sys_check_timeouts(); }

size_t ps_tcp_write(ps_tcp_t h, const uint8_t *data, size_t len) {
  struct tcp_pcb *pcb = (struct tcp_pcb *)h;
  size_t room = tcp_sndbuf(pcb);
  size_t n = len < room ? len : room;
  if (n > 0xFFFF) n = 0xFFFF;
  if (n == 0) return 0;
  if (tcp_write(pcb, data, (u16_t)n, TCP_WRITE_FLAG_COPY) != ERR_OK) return 0;
  tcp_output(pcb);
  return n;
}

size_t ps_tcp_sndbuf(ps_tcp_t h) { return tcp_sndbuf((struct tcp_pcb *)h); }

void ps_tcp_recved(ps_tcp_t h, size_t len) {
  while (len > 0) {
    u16_t chunk = len > 0xFFFF ? 0xFFFF : (u16_t)len;
    tcp_recved((struct tcp_pcb *)h, chunk);
    len -= chunk;
  }
}

void ps_tcp_shutdown_write(ps_tcp_t h) {
  tcp_shutdown((struct tcp_pcb *)h, 0, 1);
}

static void detach(struct tcp_pcb *pcb) {
  tcp_arg(pcb, NULL);
  tcp_recv(pcb, NULL);
  tcp_sent(pcb, NULL);
  tcp_err(pcb, NULL);
}

void ps_tcp_close(ps_tcp_t h) {
  struct tcp_pcb *pcb = (struct tcp_pcb *)h;
  detach(pcb);
  if (tcp_close(pcb) != ERR_OK) tcp_abort(pcb);
}

void ps_tcp_abort(ps_tcp_t h) {
  struct tcp_pcb *pcb = (struct tcp_pcb *)h;
  detach(pcb);
  tcp_abort(pcb);
}
