#ifndef PASSAGE_PSLWIP_H
#define PASSAGE_PSLWIP_H

#include <stddef.h>
#include <stdint.h>

/* Opaque handle to an lwIP tcp_pcb. Never dereferenced from Swift. */
typedef void *ps_tcp_t;

typedef struct {
  void *ctx;
  /* An IP packet lwIP wants to send back into the tunnel. */
  void (*output)(void *ctx, const uint8_t *packet, size_t len);
  /* A new TCP connection. Addresses are network byte order, 4 or 16 bytes. */
  void (*accept)(void *ctx, ps_tcp_t pcb, int is_v6,
                 const uint8_t *src_ip, uint16_t src_port,
                 const uint8_t *dst_ip, uint16_t dst_port);
  /* Data from the client. len == 0 means the client sent FIN.
     The bytes are not acknowledged until ps_tcp_recved is called. */
  void (*recv)(void *ctx, ps_tcp_t pcb, const uint8_t *data, size_t len);
  /* The client acknowledged len bytes; send buffer space is available. */
  void (*sent)(void *ctx, ps_tcp_t pcb, uint16_t len);
  /* The connection was reset or aborted; pcb is already freed. */
  void (*error)(void *ctx, ps_tcp_t pcb, int err);
} ps_callbacks;

/* Must be called once, before anything else, on the stack's queue. */
void ps_stack_init(ps_callbacks callbacks);
/* Feed one IP packet read from the tunnel. Returns 0 on success. */
int ps_stack_input(const uint8_t *packet, size_t len);
/* Run lwIP timers. Call every 250 ms. */
void ps_stack_check_timeouts(void);

/* Queue bytes for the client. Returns the number of bytes accepted (may be less than len). */
size_t ps_tcp_write(ps_tcp_t pcb, const uint8_t *data, size_t len);
/* Bytes that ps_tcp_write can accept right now. */
size_t ps_tcp_sndbuf(ps_tcp_t pcb);
/* Tell lwIP we consumed len received bytes (opens the receive window). */
void ps_tcp_recved(ps_tcp_t pcb, size_t len);
/* Send FIN (half close). */
void ps_tcp_shutdown_write(ps_tcp_t pcb);
/* Graceful close; detaches callbacks. pcb must not be used afterwards. */
void ps_tcp_close(ps_tcp_t pcb);
/* Send RST and free; pcb must not be used afterwards. */
void ps_tcp_abort(ps_tcp_t pcb);

#endif
