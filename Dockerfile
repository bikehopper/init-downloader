FROM ubuntu:24.04

WORKDIR /app

RUN apt-get update && \
    apt-get install -y curl unzip dumb-init && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

COPY main.sh main.sh

RUN chmod +x main.sh

ENTRYPOINT ["/usr/bin/dumb-init", "--"]

CMD ["./main.sh"]