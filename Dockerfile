# syntax=docker/dockerfile:1.7

FROM node:24-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY . .

ARG SITE_URL
ARG BUILD_SHA
ARG PUBLIC_WHATSAPP_NUMBER
ARG PUBLIC_WHATSAPP_NUMBER_AR
ARG PUBLIC_WHATSAPP_NUMBER_PL
ARG PUBLIC_GTM_ID

ENV SITE_URL=${SITE_URL}
ENV PUBLIC_WHATSAPP_NUMBER=${PUBLIC_WHATSAPP_NUMBER}
ENV PUBLIC_WHATSAPP_NUMBER_AR=${PUBLIC_WHATSAPP_NUMBER_AR}
ENV PUBLIC_WHATSAPP_NUMBER_PL=${PUBLIC_WHATSAPP_NUMBER_PL}
ENV PUBLIC_GTM_ID=${PUBLIC_GTM_ID}

RUN mkdir -p public/_meta \
    && printf '{"revision":"%s"}\n' "${BUILD_SHA}" \
       > public/_meta/build.json

RUN npm run check
RUN npm run validate:content
RUN npm run lint --if-present
RUN npm test --if-present
RUN npm run build

FROM nginxinc/nginx-unprivileged:stable-alpine AS runtime

COPY docker/site.conf \
  /etc/nginx/conf.d/default.conf

COPY --from=builder \
  /app/dist \
  /usr/share/nginx/html

EXPOSE 8080

# 运行期健康检查唯一定义处；Compose 不再重复定义，避免两处配置漂移。
HEALTHCHECK \
  --interval=15s \
  --timeout=3s \
  --start-period=5s \
  --retries=5 \
  CMD wget -q -O /dev/null \
      http://127.0.0.1:8080/healthz || exit 1
