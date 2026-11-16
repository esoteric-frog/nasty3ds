#include <enet/enet.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
/* server mode: client <port> <hex> server ; client <port> <hexbytes|empty> : connects (no join request) and sends one reliable packet */
int main(int c, char **v) {
    enet_initialize();
    if (c > 3) {
        ENetAddress b; b.host = ENET_HOST_ANY; enet_address_set_host(&b, "127.0.0.1"); b.port = atoi(v[1]);
        ENetHost *sv = enet_host_create(&b, 4, 1, 0, 0); ENetEvent ev; int sent = 0;
        unsigned char sb[4096]; size_t sn = 0; const char *sh = v[2];
        for (; sh[0] && sh[1]; sh += 2) { unsigned x; sscanf(sh, "%2x", &x); sb[sn++] = x; }
        for (int i = 0; i < (getenv("STREAM") ? 300 : 150); i++) {
            if (enet_host_service(sv, &ev, 100) > 0 && ev.type == ENET_EVENT_TYPE_RECEIVE && !sent) {
                printf("hostile room: got a %zu-byte packet from the joiner, answers with %zu bytes\n", ev.packet->dataLength, sn);
                enet_peer_send(ev.peer, 0, enet_packet_create(sn ? sb : NULL, sn, ENET_PACKET_FLAG_RELIABLE)); enet_host_flush(sv); sent = 1;
            }
            if (sent && getenv("STREAM")) { unsigned char one = 0xEE; for (size_t k = 0; k < sv->peerCount; k++) if (sv->peers[k].state == ENET_PEER_STATE_CONNECTED || sv->peers[k].state == ENET_PEER_STATE_DISCONNECT_LATER || sv->peers[k].state == ENET_PEER_STATE_ACKNOWLEDGING_DISCONNECT) enet_peer_send(&sv->peers[k], 0, enet_packet_create(&one, 1, ENET_PACKET_FLAG_RELIABLE)); enet_host_flush(sv); }
        }
        return 0;
    }
    ENetHost *cl = enet_host_create(NULL, 1, 1, 0, 0);
    ENetAddress a; enet_address_set_host(&a, "127.0.0.1"); a.port = atoi(v[1]);
    ENetPeer *p = enet_host_connect(cl, &a, 1, 0);
    ENetEvent e;
    if (enet_host_service(cl, &e, 3000) <= 0 || e.type != ENET_EVENT_TYPE_CONNECT) { printf("client: no connect\n"); return 1; }
    printf("client: connected with no join request\n");
    unsigned char buf[4096]; size_t n = 0; const char *h = c > 2 ? v[2] : "";
    for (; h[0] && h[1]; h += 2) { unsigned x; sscanf(h, "%2x", &x); buf[n++] = x; }
    ENetPacket *pk = enet_packet_create(n ? buf : NULL, n, ENET_PACKET_FLAG_RELIABLE);
    enet_peer_send(p, 0, pk); enet_host_flush(cl);
    printf("client: sent %zu bytes\n", n);
    for (int i = 0; i < (getenv("HOLD") ? atoi(getenv("HOLD")) : 20); i++) enet_host_service(cl, &e, 100);
    return 0;
}
