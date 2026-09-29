#!/bin/sh
# SWARM Messenger staging: open the firewall for voice and video calls. docs/STAGING.md, sections
# 2 ("Firewall") and 5d. Run once as root on the chat host; `ufw allow` skips a rule that exists,
# so running it again changes nothing.
#
#   3478/udp, 3478/tcp   coturn: TURN for one-to-one calls (turn:<host> and
#                        turn:<host>:3478?transport=tcp, the URLs the chat server hands out)
#   49160:49259/udp      coturn: relay ports, 100 = total-quota (coturn/turnserver.conf)
#   10000/udp, 10000/tcp the group-call media server (calling-backend): ICE/SRTP, UDP first, TCP
#                        for networks that block UDP
#
# coturn runs in the host's network namespace, so these rules are what makes it reachable.
# calling-backend's 10000 is a Docker-published port, which Docker forwards before UFW's rules
# are consulted (the DOCKER chains): the rule for it documents the opening rather than creating
# it, and stays correct if the backend ever moves to the host network. Nothing else is opened: no
# TURN over TLS (5349) and no coturn CLI (5766) exist.
set -eu

command -v ufw >/dev/null || { echo "ufw-calls: ufw is not installed" >&2; exit 1; }

ufw allow 3478/udp comment 'SWARM calls: TURN (coturn)'
ufw allow 3478/tcp comment 'SWARM calls: TURN over TCP (coturn)'
ufw allow 49160:49259/udp comment 'SWARM calls: TURN relay ports (coturn)'
ufw allow 10000/udp comment 'SWARM calls: group-call media (calling-backend)'
ufw allow 10000/tcp comment 'SWARM calls: group-call media over TCP (calling-backend)'

ufw status numbered
