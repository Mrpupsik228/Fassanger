format ELF64

section '.text' executable

public htons

htons:
    mov ax, di          ; Move the low 16 bits of rdi to ax
    xchg al, ah         ; Swap bytes for network byte order
    ret
