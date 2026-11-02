#ifndef YGG_UTUN_H
#define YGG_UTUN_H

/// Returns the file descriptor of the utun interface owned by this
/// NEPacketTunnelProvider, or -1 if it cannot be found.
int ygg_find_utun_fd(void);

#endif
