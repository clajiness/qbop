# Description: Dockerfile for qbop
FROM ruby:3.4.1-slim

# set the version environment variable
ARG VERSION_ARG
ENV VERSION=${VERSION_ARG}

# set the working directory
WORKDIR /opt/qbop/

# create necessary directories and copy files
COPY config.ru Gemfile Gemfile.lock /opt/qbop/
COPY sidekiq.service /etc/systemd/system/
COPY config/ /opt/qbop/config/
COPY data/ /opt/qbop/data/
COPY jobs/ /opt/qbop/jobs/
COPY service/ /opt/qbop/service/
COPY views/ /opt/qbop/views/
RUN mkdir -p /opt/qbop/log/

# create volume for log files
VOLUME /opt/qbop/data/

# install necessary packages
RUN \
apt update; \
apt install lsb-release curl gpg; \
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg; \
chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg; \
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list; \
apt update; \
apt install -y build-essential natpmpc redis; \
bundle install; \
systemctl daemon reload; \
systemctl enable redis-server; \
systemctl start redis-server; \
systemctl enable sidekiq; \
systemctl start sidekiq;

# set up entrypoint
ENTRYPOINT ["rackup", "/opt/qbop/config.ru"]
