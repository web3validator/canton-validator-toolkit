FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json tsconfig.json ./
RUN npm install

COPY src ./src
RUN npm run build

FROM node:20-alpine AS runner

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY --from=builder /app/dist ./dist
COPY src/storage/schema.sql ./dist/storage/schema.sql

ENV NODE_ENV=production

EXPOSE 3000

CMD ["node", "dist/index.js"]
