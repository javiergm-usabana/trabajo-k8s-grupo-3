FROM node:20-alpine AS builder

WORKDIR /app

RUN npm install --global pnpm@10.17.1

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY nest-cli.json tsconfig.json tsconfig.build.json ./
COPY src ./src

RUN pnpm run build \
    && pnpm prune --prod

FROM node:20-alpine AS runtime

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

RUN addgroup --system --gid 1001 kubescope \
    && adduser --system --uid 1001 --ingroup kubescope kubescope

COPY --from=builder --chown=kubescope:kubescope /app/package.json ./package.json
COPY --from=builder --chown=kubescope:kubescope /app/node_modules ./node_modules
COPY --from=builder --chown=kubescope:kubescope /app/dist ./dist

USER kubescope

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:3000/health || exit 1

CMD ["node", "dist/main.js"]
