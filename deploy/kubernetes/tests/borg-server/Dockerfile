FROM ghcr.io/borgmatic-collective/borgmatic:2.1.10

RUN apk add --no-cache openssh-server \
	&& chmod 755 /usr /usr/local /usr/local/bin /etc \
	&& adduser -D -h /home/borg borg \
	&& echo 'borg:*' | chpasswd -e

COPY sshd_config /etc/ssh/sshd_config

ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e"]
