FROM ghcr.io/borgmatic-collective/borgmatic:2.1.10@sha256:25a97d84a2371c385c0031a02b64f7167de85631a85b84ef46dc01a80010d19e

RUN apk add --no-cache openssh-server \
	&& chmod 755 /usr /usr/local /usr/local/bin /etc \
	&& adduser -D -h /home/borg borg \
	&& echo 'borg:*' | chpasswd -e

COPY sshd_config /etc/ssh/sshd_config

ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e"]
