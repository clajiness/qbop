# Description: Dockerfile for qbop
FROM ruby:3.3.6-slim

# set the working directory
WORKDIR /opt/qbop/

# create necessary directories and copy files
COPY qbop.rb config.yml version.yml /opt/qbop/
COPY service/ /opt/qbop/service/
RUN mkdir -p /opt/qbop/log/

# create volume for log files
VOLUME /opt/qbop/log/

# install necessary packages
RUN \
apt update; \
apt install -y natpmpc;

# 
ENTRYPOINT ["ruby", "/opt/qbop/qbop.rb"]
