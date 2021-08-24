#!/usr/bin/env python3

import socket

# Constants for module users
cdef int COPY_NONE = 0
cdef int COPY_META = 1
cdef int COPY_PACKET = 2

cdef u_int16_t DEFAULT_MAX_QUEUELEN = 1024
cdef u_int16_t MaxPacketSize = 0xFFFF

# buffer size - metadata size
cdef u_int16_t MaxCopySize = 4096 - 80

# Socket queue should hold max number of packets of copy size bytes
# formula: DEF_MAX_QUEUELEN * (MaxCopySize+SockOverhead) / 2
cdef u_int32_t SockRcvSize = 1024 * 4796 // 2

cdef int nf_callback(nfq_q_handle *qh, nfgenmsg *nfmsg, nfq_data *nfa, void *data) with gil:

    cdef NetfilterQueue nfqueue = <NetfilterQueue>data
    cdef object user_callback = <object>nfqueue.user_callback

    packet = CPacket()
    with nogil:
        packet.parse(qh, nfa)

    user_callback(packet)

    return 1


cdef class CPacket:
    '''parent class designed to index/parse full tcp/ip packets (including ethernet). two alternate
    constructors are supplied to support nfqueue or raw sockets.
    raw socket:
        packet = RawPacket.interface(data, address, socket)
    nfqueue:
        packet = RawPacket.netfilter(nfqueue)
    the before_exit method can be overridden to extend the parsing functionality, for example to group
    objects in namedtuples or to index application data.
    '''

    def __cinit__(self):
        self._verdict_is_set = False
        self._mark = 0

        # self.protocol = 0

    # def __str__(self):
    #     cdef iphdr *hdr = <iphdr*>self.payload
    #     protocol = PROTOCOLS.get(hdr.protocol, "Unknown protocol")
    #
    #     return "%s packet, %s bytes" % (protocol, self.payload_len)

    # NOTE: this will be callback target for nfqueue
    cdef void parse(self, nfq_q_handle *qh, nfq_data *nfa) nogil:
        '''Alternate constructor. Used to start listener/proxy instances using nfqueue bindings.'''

        '''Assign a packet from NFQ to this object. Parse the header and load local values.'''

        # cdef unsigned char *data

        self._qh = qh
        self._nfa = nfa
        self._hdr = nfq_get_msg_packet_hdr(nfa)

        # self.id = ntohl(self._hdr.packet_id)
        # self.hw_protocol = ntohs(self._hdr.hw_protocol)
        # self.hook = self._hdr.hook

        self.data_len = nfq_get_payload(self._nfa, &self.data)
        # TODO: figure this out. cant use no gil if its here.
        # if self.payload_len < 0:
        #     raise OSError("Failed to get payload of packet.")

        # timestamp gets assigned via pointer/struct -> time_val: (t_sec, t_usec).
        nfq_get_timestamp(self._nfa, &self.timestamp)

        self._mark = nfq_get_nfmark(nfa)

        # splitting packet by tcp/ip layers
        self._parse()

        # if (self.continue_condition):
        #     self._before_exit()

    cdef void _parse(self) nogil:
        '''Index tcp/ip packet layers 3 & 4 for use as instance objects.
        the before_exit method will be called before returning, which can be used to create
        subclass specific objects like namedtuples or application layer data.'''

        cdef iphdr *ip_header = <iphdr*>self.data

        cdef u_int8_t iphdr_len = (ip_header.tos & 15) * 4

        cdef tcphdr *tcp_header
        cdef udphdr *udp_header
        cdef icmphdr *icmp_header

        self.ip_header = ip_header
        if (ip_header.protocol == IPPROTO_TCP):

            self.tcp_header = <tcphdr*>self.data[iphdr_len]

        if (ip_header.protocol == IPPROTO_UDP):

            self.udp_header = <udphdr*>self.data[iphdr_len]

        if (ip_header.protocol == IPPROTO_ICMP):

            self.icmp_header = <icmphdr*>self.data[iphdr_len]

    cdef void verdict(self, u_int32_t verdict):
        '''Call appropriate set_verdict... function on packet.'''

        if self._verdict_is_set:
            raise RuntimeWarning("Verdict already given for this packet.")

        cdef u_int32_t modified_payload_len = 0
        cdef unsigned char *modified_payload = NULL

        # rewriting payload data/len
        if self._given_payload:
            modified_payload_len = len(self._given_payload)
            modified_payload = self._given_payload

        if self._modified_mark:
            nfq_set_verdict2(
                self._qh, self.id, verdict, self._modified_mark, modified_payload_len, modified_payload
            )

        else:
            nfq_set_verdict(
                self._qh, self.id, verdict, modified_payload_len, modified_payload
            )

        self._verdict_is_set = True

    def get_raw_packet(self):
        '''returns layer 3-7 of packet data.'''

        return self.data[:self.data_len]

    def get_ip_header(self):
        '''return layer3 of packet data as a tuple converted directly from C struct.'''

        cdef PyTupleObject ip_header

        ip_header = (
            self.ip_header.tos,
            self.ip_header.tot_len,
            self.ip_header.id,
            self.ip_header.frag_off,
            self.ip_header.ttl,
            self.ip_header.protocol,
            self.ip_header.check,
            ntohl(self.ip_header.saddr),
            ntohl(self.ip_header.daddr)
        )

        return ip_header

    # def _before_exit(self):
    #     '''executes before returning from parse call.
    #     May be overridden.
    #     '''
    #     pass
    #
    # @property
    # def continue_condition(self):
    #     '''controls whether the _before_exit method gets called. must return a boolean.
    #     May be overridden.
    #     '''
    #     return True


cdef class NetfilterQueue:
    '''Handle a single numbered queue.'''

    def __cinit__(self, *args, **kwargs):
        self.af = kwargs.get('af', PF_INET)

        self.h = nfq_open()
        if self.h == NULL:
            raise OSError('Failed to open NFQueue.')

        # This does NOT kick out previous running queues
        nfq_unbind_pf(self.h, self.af)

        if nfq_bind_pf(self.h, self.af) < 0:
            raise OSError('Failed to bind family %s. Are you root?' % self.af)

    def __dealloc__(self):
        if self.qh != NULL:
            nfq_destroy_queue(self.qh)

        # Don't call nfq_unbind_pf unless you want to disconnect any other
        # processes using this libnetfilter_queue on this protocol family!
        nfq_close(self.h)

    def bind(self, int queue_num, object user_callback, u_int16_t max_len=DEFAULT_MAX_QUEUELEN,
            u_int8_t mode=NFQNL_COPY_PACKET, u_int16_t range=MaxPacketSize, u_int32_t sock_len=SockRcvSize):
        '''Create and bind to a new queue.'''

        cdef unsigned int newsiz

        self.user_callback = user_callback
        self.qh = nfq_create_queue(self.h, queue_num, <nfq_callback*>nf_callback, <void*>self)
        if self.qh == NULL:
            raise OSError(f'Failed to create queue {queue_num}')

        if range > MaxCopySize:
            range = MaxCopySize

        if nfq_set_mode(self.qh, mode, range) < 0:
            raise OSError("Failed to set packet copy mode.")

        nfq_set_queue_maxlen(self.qh, max_len)

        newsiz = nfnl_rcvbufsiz(nfq_nfnlh(self.h), sock_len)
        if newsiz != sock_len * 2:
            raise RuntimeWarning("Socket rcvbuf limit is now %d, requested %d." % (newsiz, sock_len))

    def unbind(self):
        '''Destroy the queue.'''

        if self.qh != NULL:
            nfq_destroy_queue(self.qh)

        self.qh = NULL
        # See warning about nfq _unbind_pf in __dealloc__ above.

    def get_fd(self):
        '''Get the file descriptor of the queue handler.'''

        return nfq_fd(self.h)

    def run(self, bint block=True):
        '''Accept packets using recv.'''

        cdef int fd = self.get_fd()
        cdef char buf[4096]
        cdef int rv
        cdef int recv_flags

        recv_flags = 0

        while True:
            with nogil:
                rv = recv(fd, buf, sizeof(buf), recv_flags)

            print(rv)

            if (rv >= 0):
                nfq_handle_packet(self.h, buf, rv)

            else:
                if errno != ENOBUFS:
                    break
