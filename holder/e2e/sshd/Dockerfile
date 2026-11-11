# 端到端测试用的 sshd：一个能用公钥登录的普通用户 dev，登录 shell 是 bash。
FROM alpine:3.21
RUN apk add --no-cache openssh bash coreutils procps \
    && ssh-keygen -A \
    && adduser -D -s /bin/bash dev \
    && echo 'dev:dev' | chpasswd
COPY authorized_keys /home/dev/.ssh/authorized_keys
RUN chown -R dev:dev /home/dev/.ssh && chmod 700 /home/dev/.ssh && chmod 600 /home/dev/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
