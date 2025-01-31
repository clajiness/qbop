# Description: Dockerfile for qbop
FROM ruby:3.4.1

# set the version environment variable
ARG VERSION_ARG
ENV VERSION=${VERSION_ARG}

# set the working directory
WORKDIR /opt/qbop/

# create necessary directories and copy files
COPY config.ru Gemfile Gemfile.lock /opt/qbop/
COPY data/ /opt/qbop/data/
COPY framework/ /opt/qbop/framework/
COPY jobs/ /opt/qbop/jobs/
COPY service/ /opt/qbop/service/
COPY views/ /opt/qbop/views/
RUN mkdir -p /opt/qbop/log/

# create volume for log files
VOLUME /opt/qbop/data/

# install necessary packages
RUN \
apt update; \
apt install -y build-essential libz-dev libsqlite3-dev libsqlite3-ruby natpmpc; \
bundle install;

# expose the port
EXPOSE 4567

# set up entrypoint
ENTRYPOINT ["rackup", "/opt/qbop/config.ru", "-p", "4567"]
