# Description: Dockerfile for qbop
FROM ruby:4.0.6-slim

# set the working directory
WORKDIR /opt/qbop/

# install necessary packages
RUN \
apt update; \
apt install -y build-essential pkg-config natpmpc wireguard dnsutils;

# create qbop user and group
RUN groupadd -g 1234 qbop && useradd -m -u 1234 -g qbop qbop;

# install necessary ruby gems before copying application source
COPY Gemfile Gemfile.lock /opt/qbop/
RUN chown -R qbop:qbop /opt/qbop/
USER qbop
RUN bundle install;

# copy application source and create necessary directories
USER root
COPY config.ru Rakefile /opt/qbop/
COPY db/ /opt/qbop/db/
COPY framework/ /opt/qbop/framework/
COPY jobs/ /opt/qbop/jobs/
COPY models/ /opt/qbop/models/
COPY public/ /opt/qbop/public/
COPY service/ /opt/qbop/service/
COPY views/ /opt/qbop/views/

RUN mkdir -p /opt/qbop/data/
RUN mkdir -p /opt/qbop/log/

# set ownership
RUN chown -R qbop:qbop /opt/qbop/

# set build identity environment variables after cacheable build layers
ARG VERSION=development
ARG COMMIT_SHA=unknown
ARG BUILD_DATE=unknown
ENV VERSION=${VERSION} \
    COMMIT_SHA=${COMMIT_SHA} \
    BUILD_DATE=${BUILD_DATE}

# switch to non-root user
USER qbop

# create volumes
VOLUME /opt/qbop/data/
VOLUME /opt/qbop/log/

# expose the ui port
EXPOSE 4567

# set up entrypoint
ENTRYPOINT ["bundle", "exec", "puma", "-p", "4567", "-e", "production"]
