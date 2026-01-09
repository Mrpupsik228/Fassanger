BUILDDIR = build
TEMPDIR = temp
SERVER_TARGET = build/messenger_server
CLIENT_TARGET = build/messenger_client
ASM = fasm

all: $(SERVER_TARGET) $(CLIENT_TARGET)

$(SERVER_TARGET): $(BUILDDIR) $(TEMPDIR)/server.o $(TEMPDIR)/htons.o
	ld $(TEMPDIR)/server.o $(TEMPDIR)/htons.o -o $(SERVER_TARGET)

$(CLIENT_TARGET): $(BUILDDIR) $(TEMPDIR)/client.o $(TEMPDIR)/htons.o
	ld $(TEMPDIR)/client.o $(TEMPDIR)/htons.o -o $(CLIENT_TARGET)

$(TEMPDIR)/server.o: src/server.asm $(TEMPDIR)
	$(ASM) src/server.asm $(TEMPDIR)/server.o

$(TEMPDIR)/client.o: src/client.asm $(TEMPDIR)
	$(ASM) src/client.asm $(TEMPDIR)/client.o

$(TEMPDIR)/htons.o: src/htons.asm $(TEMPDIR)
	$(ASM) src/htons.asm $(TEMPDIR)/htons.o

$(TEMPDIR):
	mkdir -p $(TEMPDIR)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR) $(TEMPDIR)
