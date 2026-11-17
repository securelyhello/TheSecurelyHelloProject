# Securely Hello server: directory + signaling switchboard + ciphertext relay.
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:24-alpine
ENV NODE_ENV=production PORT=8787 HOST=0.0.0.0
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY migrations ./migrations
COPY src ./src
# Attachment folder for ATTACHMENT_STORAGE=filesystem (mount a volume here);
# owned by the unprivileged user so a fresh named volume inherits it.
RUN mkdir -p /data/attachments && chown -R node:node /data
USER node
EXPOSE 8787
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
# node is PID 1 and handles SIGTERM itself (graceful drain in src/index.js).
CMD ["node", "src/index.js"]
