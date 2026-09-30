FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh /root/.codex/sessions /root/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin \
    && chmod 700 /root/.ssh \
    && ln -s /usr/local/bin/node /root/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node
COPY --chmod=755 codex /usr/local/bin/codex
CMD ["/usr/sbin/sshd", "-D", "-e", "-o", "PasswordAuthentication=no", "-o", "PermitRootLogin=prohibit-password"]
