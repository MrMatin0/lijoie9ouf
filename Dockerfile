FROM alpine:3.20

RUN apk add --no-cache nginx curl unzip ca-certificates tzdata && \
    mkdir -p /run/nginx /etc/app /var/www/html

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
