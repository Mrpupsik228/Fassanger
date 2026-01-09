format ELF64
public _start

extrn htons

section '.data' writable
; Messages
connect_msg_prefix db '[INFO]: Connecting to server at ', 0
connect_msg_prefix_len equ 33
connect_error_msg db '[FATAL]: Connection failed', 10, 0
connect_error_msg_len equ 27
socket_error_msg db '[FATAL]: Failed to create socket', 10, 0
socket_error_msg_len equ 34
connected_msg db '[INFO]: Connected to server', 10, 0
connected_msg_len equ 28
prompt db '> ', 0
prompt_len equ 2
newline db 10, 0
newline_len equ 1
clear_line db 13, 27, '[K'   ; CR + ANSI escape to clear line
clear_line_len equ 4
colon db ':', 0
default_username db 'User', 0
default_username_len equ 4
default_ip db 127, 0, 0, 1  ; 127.0.0.1
default_port dw 8080

; Server address
server_ip: rb 4
server_port: rw 1

section '.bss' writable
sockfd: rq 1
address: rw 8
input_buffer: rb 1024
input_len: rq 1
recv_buffer: rb 1024
timespec_req: rq 2  ; tv_sec and tv_nsec
username: rb 64     ; User's chosen username
send_buffer: rb 1100  ; Buffer for messages
connect_info_buffer: rb 128  ; Buffer for connection info message

section '.text' executable

print_string:
    ; Input: rsi = string, rdx = length
    mov rax, 1          ; syscall: write
    mov rdi, 1          ; file descriptor: stdout
    syscall
    ret

strlen:
    ; Input: rdi = string pointer
    ; Output: rax = length
    push rdi
    xor rax, rax
.loop:
    cmp byte [rdi], 0
    je .done
    inc rdi
    inc rax
    jmp .loop
.done:
    pop rdi
    ret

atoi:
    ; Input: rdi = string pointer
    ; Output: rax = integer value
    push rbx
    push rcx
    xor rax, rax        ; result
    xor rcx, rcx        ; current char
.loop:
    movzx rcx, byte [rdi]
    cmp rcx, 0
    je .done
    cmp rcx, '0'
    jl .done
    cmp rcx, '9'
    jg .done
    sub rcx, '0'
    imul rax, 10
    add rax, rcx
    inc rdi
    jmp .loop
.done:
    pop rcx
    pop rbx
    ret

parse_ip:
    ; Input: rdi = IP string (e.g., "192.168.1.1")
    ; Output: Stores IP in server_ip array in network byte order
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9

    lea r9, [server_ip]  ; pointer to where we'll store the bytes
    xor r8, r8           ; octet counter
    mov rsi, rdi         ; save start

.parse_octet:
    ; Parse the next octet
    mov rdi, rsi
    call atoi            ; rax = octet value

    ; Store this byte directly
    mov [r9 + r8], al
    inc r8

    ; Find the next '.' or null
.find_delim:
    cmp byte [rsi], 0
    je .done_parsing
    cmp byte [rsi], '.'
    je .next_octet
    inc rsi
    jmp .find_delim

.next_octet:
    inc rsi              ; skip the '.'
    cmp r8, 4
    jl .parse_octet

.done_parsing:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

print_number_to_buffer:
    ; Input: rax = number to print, rdi = buffer pointer
    ; Output: rdi = updated buffer pointer
    push rbx
    push r10

    mov rbx, rdi        ; save buffer start
    mov r8, rax         ; save number
    mov r9, 10          ; divisor

    cmp r8, 0
    jne .not_zero
    mov byte [rdi], '0'
    inc rdi
    jmp .done_print

.not_zero:
    mov r10, rdi        ; save start position
    mov rax, r8

.count_loop:
    cmp rax, 0
    je .reverse
    xor rdx, rdx
    div r9              ; rax = quotient, rdx = remainder
    add dl, '0'
    mov [rdi], dl
    inc rdi
    jmp .count_loop

.reverse:
    mov rcx, rdi
    dec rcx             ; end pointer
    mov rax, r10        ; start pointer

.reverse_loop:
    cmp rax, rcx
    jge .done_print
    mov bl, [rax]
    mov dl, [rcx]
    mov [rax], dl
    mov [rcx], bl
    inc rax
    dec rcx
    jmp .reverse_loop

.done_print:
    pop r10
    pop rbx
    ret

socket_error:
    mov rsi, socket_error_msg
    mov rdx, socket_error_msg_len
    call print_string
    
    mov rax, 60         ; syscall: exit
    mov rdi, 1          ; status: 1
    syscall

connect_error:
    mov rsi, connect_error_msg
    mov rdx, connect_error_msg_len
    call print_string
    
    mov rax, 3
    mov rdi, [sockfd]
    syscall
    
    mov rax, 60
    mov rdi, 1
    syscall

main_loop:
    ; Reset input length for new message
    mov qword [input_len], 0

.read_loop:
    ; Small sleep to prevent CPU spinning (10ms)
    mov qword [timespec_req], 0          ; tv_sec = 0
    mov qword [timespec_req + 8], 10000000  ; tv_nsec = 10,000,000 (10ms)
    mov rax, 35                          ; syscall: nanosleep
    lea rdi, [timespec_req]
    xor rsi, rsi
    syscall

    ; Check for incoming messages from server (non-blocking)
    mov rdi, [sockfd]
    lea rsi, [recv_buffer]
    mov rdx, 1024       ; buffer size
    mov r10, 0x40       ; flags = MSG_DONTWAIT (non-blocking)
    xor r8, r8          ; src_addr = NULL
    xor r9, r9          ; addrlen = NULL
    mov rax, 45         ; syscall: recvfrom
    syscall

    ; Check for server disconnection (recv returned 0)
    cmp rax, 0
    je .exit_loop

    ; Check for EAGAIN/EWOULDBLOCK (-11) which is normal for non-blocking
    cmp rax, -11
    je .no_server_msg

    ; Check for other errors (but not EAGAIN)
    cmp rax, 0
    jl .exit_loop

    ; If we got a message, print it
    push rax            ; save message length

    ; Move cursor to start of line and clear it (for cleaner display)
    mov rax, 1
    mov rdi, 1
    lea rsi, [clear_line]
    mov rdx, clear_line_len
    syscall

    ; Print received message to stdout
    pop rdx             ; restore message length
    push rdx            ; save it again
    mov rax, 1          ; syscall: write
    mov rdi, 1          ; stdout
    lea rsi, [recv_buffer]
    syscall

    ; Print newline after message
    mov rax, 1
    mov rdi, 1
    lea rsi, [newline]
    mov rdx, newline_len
    syscall

    ; Reprint the prompt
    mov rax, 1
    mov rdi, 1
    lea rsi, [prompt]
    mov rdx, prompt_len
    syscall

    ; Reprint what user has typed so far
    mov rdx, [input_len]
    cmp rdx, 0
    je .skip_reprint
    mov rax, 1
    mov rdi, 1
    lea rsi, [input_buffer]
    syscall

.skip_reprint:
    pop rdx             ; clean up stack

.no_server_msg:
    ; Calculate current position in buffer
    lea rsi, [input_buffer]
    add rsi, [input_len]

    ; Read one byte at a time from stdin (non-blocking)
    mov rax, 0          ; syscall: read
    mov rdi, 0          ; file descriptor: stdin
    mov rdx, 1          ; read 1 byte
    syscall

    cmp rax, 0
    je .exit_loop       ; EOF

    ; Check for EAGAIN (no data available)
    cmp rax, -11        ; -EAGAIN = -11
    je .read_loop       ; No data, try again

    cmp rax, 0
    jl .exit_loop       ; Other error

    ; Get the byte we just read
    mov rax, [input_len]
    mov cl, byte [input_buffer + rax]

    ; Increment length
    inc qword [input_len]

    ; Check if it's newline
    cmp cl, 10          ; newline character
    jne .read_loop

    ; Don't include newline in message
    dec qword [input_len]

    ; Send the message directly (server will prepend username)
    mov rdi, [sockfd]
    lea rsi, [input_buffer]
    mov rdx, [input_len]
    xor r10, r10        ; flags = 0
    xor r8, r8          ; dest_addr = NULL (connected socket)
    xor r9, r9          ; addrlen = 0
    mov rax, 44         ; syscall: sendto
    syscall

    ; Check if send failed (server disconnected)
    cmp rax, 0
    jl .exit_loop

    ; Print prompt after message
    mov rax, 1
    mov rdi, 1
    lea rsi, [prompt]
    mov rdx, prompt_len
    syscall

    jmp main_loop

.exit_loop:
    mov rax, 3
    mov rdi, [sockfd]
    syscall
    
    mov rax, 60
    xor rdi, rdi
    syscall

_start:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    ; Parse command-line arguments: ./client [ip] [port] [username]
    ; Set defaults
    mov eax, dword [default_ip]
    mov dword [server_ip], eax
    mov ax, word [default_port]
    mov [server_port], ax

    lea rdi, [username]
    lea rsi, [default_username]
    mov rcx, default_username_len
.set_default_user:
    cmp rcx, 0
    je .default_user_done
    mov al, byte [rsi]
    mov byte [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .set_default_user
.default_user_done:
    mov byte [rdi], 0

    ; Check argc for IP argument
    mov rax, [rbp + 8]
    cmp rax, 2
    jl .args_parsed

    ; Parse IP (stores directly in server_ip)
    mov rdi, [rbp + 24]  ; argv[1]
    call parse_ip

    ; Check argc for port argument
    mov rax, [rbp + 8]
    cmp rax, 3
    jl .args_parsed

    ; Parse port
    mov rdi, [rbp + 32]  ; argv[2]
    call atoi
    mov [server_port], ax

    ; Check argc for username argument
    mov rax, [rbp + 8]
    cmp rax, 4
    jl .args_parsed

    ; Copy username from argv[3]
    mov rsi, [rbp + 40]  ; argv[3]
    lea rdi, [username]
    mov rcx, 63          ; max username length
.copy_username_arg:
    mov al, byte [rsi]
    cmp al, 0
    je .username_done
    mov byte [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .copy_username_arg
.username_done:
    mov byte [rdi], 0    ; null terminate

.args_parsed:
    ; Create socket
    mov rax, 41          ; syscall: socket
    mov rdi, 2           ; AF_INET
    mov rsi, 1           ; SOCK_STREAM
    mov rdx, 0           ; IPPROTO_IP
    syscall

    cmp rax, 0
    jl socket_error

    mov [sockfd], rax

    ; Print connecting message with actual IP and port
    mov rsi, connect_msg_prefix
    mov rdx, connect_msg_prefix_len
    call print_string

    lea rsi, [connect_info_buffer]
    mov rdi, rsi

    ; Format IP:port
    movzx rax, byte [server_ip]
    call print_number_to_buffer
    mov byte [rdi], '.'
    inc rdi

    movzx rax, byte [server_ip + 1]
    call print_number_to_buffer
    mov byte [rdi], '.'
    inc rdi

    movzx rax, byte [server_ip + 2]
    call print_number_to_buffer
    mov byte [rdi], '.'
    inc rdi

    movzx rax, byte [server_ip + 3]
    call print_number_to_buffer
    mov byte [rdi], ':'
    inc rdi

    movzx rax, word [server_port]
    call print_number_to_buffer

    ; Print the info and newline
    lea rax, [connect_info_buffer]
    sub rdi, rax
    mov rdx, rdi
    lea rsi, [connect_info_buffer]
    call print_string

    mov rax, 1
    mov rdi, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall

    ; Prepare address structure
    xor rax, rax
    mov [address], rax
    mov [address + 8], rax

    mov word [address], 2            ; AF_INET

    movzx rdi, word [server_port]
    call htons
    mov word [address + 2], ax       ; port

    ; Set IP address
    mov eax, [server_ip]
    mov [address + 4], eax

    ; Connect to server
    mov rax, 42          ; syscall: connect
    mov rdi, [sockfd]
    lea rsi, [address]
    mov rdx, 16          ; size of sockaddr_in
    syscall

    cmp rax, 0
    jl connect_error

    ; Print connected message
    mov rsi, connected_msg
    mov rdx, connected_msg_len
    call print_string

    ; Send username to server
    lea rdi, [username]
    call strlen
    mov rdx, rax         ; username length

    mov rdi, [sockfd]
    lea rsi, [username]
    xor r10, r10         ; flags = 0
    xor r8, r8
    xor r9, r9
    mov rax, 44          ; syscall: sendto
    syscall

    ; Set stdin to non-blocking mode using fcntl
    mov rax, 72         ; syscall: fcntl
    mov rdi, 0          ; stdin
    mov rsi, 4          ; F_SETFL (set file status flags)
    mov rdx, 2048       ; O_NONBLOCK = 2048 (0x800)
    syscall

    ; Print initial prompt
    mov rax, 1
    mov rdi, 1
    lea rsi, [prompt]
    mov rdx, prompt_len
    syscall

    jmp main_loop
