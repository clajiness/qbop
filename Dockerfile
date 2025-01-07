# Description: Dockerfile for qbop
FROM ruby:3.4-slim

# set the version environment variable
ARG VERSION
ENV VERSION=${VERSION}

# set the working directory
WORKDIR /opt/qbop/

# create necessary directories and copy files
COPY Gemfile Gemfile.lock qbop.rb /opt/qbop/
COPY service/ /opt/qbop/service/
RUN mkdir -p /opt/qbop/log/

# create volume for log files
VOLUME /opt/qbop/log/

# install necessary packages
RUN \
apt update; \
apt install -y build-essential natpmpc; \
bundle install;

# set up entrypoint
ENTRYPOINT ["ruby", "/opt/qbop/qbop.rb"]
