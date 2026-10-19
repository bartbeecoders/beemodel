# BeeModelHome - the static website (https://beemodel.hideterms.com), served by
# nginx as an unprivileged user on port 8080. Build the site first
# (python3 tools/build.py); the image only copies site/.
FROM docker.io/nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --chmod=644 site/ /usr/share/nginx/html/
USER root
RUN find /usr/share/nginx/html -type d -exec chmod 755 {} +
USER 101
EXPOSE 8080
