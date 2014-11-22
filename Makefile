CFLAGS 			= -Wall -g
CLIBS=`pkg-config --libs --cflags glib-2.0`

all:
	gcc $(CFLAGS) $(CLIBS) src/client.c src/communication.c src/regex.c src/socket.c -o bin/client.bin $(CLIBS)

clean:
	rm *.o
