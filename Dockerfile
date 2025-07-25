# Description: Dockerfile for qbop
FROM ruby:3.4.5-slim

# set the version environment variable
ARG VERSION
ENV VERSION=${VERSION}

# set the working directory
WORKDIR /opt/qbop/

# create necessary directories and copy files
COPY config.ru Gemfile Gemfile.lock /opt/qbop/
COPY data/ /opt/qbop/data/
COPY framework/ /opt/qbop/framework/
COPY jobs/ /opt/qbop/jobs/
COPY public/ /opt/qbop/public/
COPY service/ /opt/qbop/service/
COPY views/ /opt/qbop/views/
RUN mkdir -p /opt/qbop/data/log/

# create volume for log files
VOLUME /opt/qbop/data/

# install necessary packages
RUN \
apt update; \
apt install -y build-essential pkg-config natpmpc; \
bundle install;

# expose the ui port
EXPOSE 4567

# set up entrypoint
ENTRYPOINT ["bundle", "exec", "puma", "-p", "4567", "-e", "production"]
