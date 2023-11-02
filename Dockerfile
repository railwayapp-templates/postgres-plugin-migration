FROM alpine

RUN apk update && apk add postgresql-client bash ncurses

WORKDIR app

ADD . .

CMD bash migrate.sh
