format ELF64
public _start

extrn htons

section '.data' writable
; Error messages
socket_error_msg db '[FATAL]: Failed to create socket', 10, 0
socket_error_msg_len equ 34
server_bind_error_msg db '[FATAL]: Failed to bind socket', 10, 0
server_bind_error_msg_len equ 32
socket_listen_error_msg db '[FATAL]: Failed to listen port', 10, 0
socket_listen_error_msg_len equ 32
server_start_msg db '[INFO]: Messenger server started on ', 0
server_start_msg_len equ 37
client_connected_msg db '[INFO]: Client connected: ', 0
client_connected_msg_len equ 26
client_disconnected_msg db '[INFO]: Client disconnected: ', 0
client_disconnected_msg_len equ 29
usage_msg db 'Usage: ./messenger_server [ip] [port]', 10, 'Defaults to 0.0.0.0:8080', 10, 0
usage_msg_len equ 63
newline db 10, 0

; Default values
default_ip db 0, 0, 0, 0  ; 0.0.0.0
default_port dw 8080

; Input buffer
input_buffer: db 1024 dup(0)
input_buffer_len: dq 0

; Message formatting
formatted_msg_buffer: db 1200 dup(0)  ; Buffer for "[username]: message"
nick_command db '/nick ', 0
nick_command_len equ 6

section '.bss' writable
server_sockfd: rq 1
address: rw 8
client_sockfd: rq 1
timespec_req: rq 2  ; tv_sec and tv_nsec
clients: rq 100     ; Array of client socket file descriptors
client_names: rb 6400  ; Array of client names (100 clients * 64 bytes each)
num_clients: rq 1   ; Number of connected clients
bind_ip: rb 4       ; IP to bind to
bind_port: rw 1     ; Port to bind to
server_info_buffer: rb 128  ; Buffer for server startup message

section '.text' executable

socket_error:
    mov rax, 1                          ; syscall: write
    mov rdi, 2                          ; file descriptor: stderr
    mov rsi, socket_error_msg           ; pointer to message
    mov rdx, socket_error_msg_len       ; message length
    syscall

    mov rax, 60         ; syscall: exit
    mov rdi, 1          ; status: 1
    syscall

socket_bind_error:
    mov rax, 1                          ; syscall: write
    mov rdi, 2                          ; file descriptor: stderr
    mov rsi, server_bind_error_msg      ; pointer to message
    mov rdx, server_bind_error_msg_len  ; message length
    syscall

    mov rax, 3    ; syscall: close
    mov rdi, [server_sockfd]
    syscall

    mov rax, 60         ; syscall: exit
    mov rdi, 1          ; status: 1
    syscall

socket_listen_error:
    mov rax, 1                          ; syscall: write
    mov rdi, 2                          ; file descriptor: stderr
    mov rsi, socket_listen_error_msg    ; pointer to message
    mov rdx, socket_listen_error_msg_len; message length
    syscall

    mov rax, 3    ; syscall: close
    mov rdi, [server_sockfd]
    syscall

    mov rax, 60         ; syscall: exit
    mov rdi, 1          ; status: 1
    syscall

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
    ; Output: Stores IP in bind_ip array in network byte order
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9

    lea r9, [bind_ip]   ; pointer to where we'll store the bytes
    xor r8, r8          ; octet counter
    mov rsi, rdi        ; save start

.parse_octet:
    ; Parse the next octet
    mov rdi, rsi
    call atoi           ; rax = octet value

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
    inc rsi             ; skip the '.'
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
    ; Output: rdi = updated buffer pointer (after the number)
    ; Modifies: rax, rcx, rdx, r8, r9
    push rbx
    push r10

    mov rbx, rdi        ; save buffer start
    mov r8, rax         ; save number
    mov r9, 10          ; divisor

    ; Handle zero case
    cmp r8, 0
    jne .not_zero
    mov byte [rdi], '0'
    inc rdi
    jmp .done_print

.not_zero:
    ; Count digits and build number in reverse
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
    ; Reverse the digits
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

add_client:
    ; Input: rdi = client socket fd
    push rbx
    push r12
    push r13

    mov r12, rdi        ; save socket fd

    mov rax, [num_clients]
    cmp rax, 100
    jge .skip_add

    mov rbx, rax        ; rbx = client index

    ; Add socket to clients array
    mov rsi, clients
    mov [rsi + rbx * 8], r12

    ; Receive username from client (blocking, should arrive immediately)
    ; Calculate pointer to this client's name storage
    imul r13, rbx, 64   ; offset = index * 64
    lea rsi, [client_names]
    add rsi, r13

    mov rdi, r12        ; socket fd
    mov rdx, 63         ; max name length (leave room for null)
    xor r10, r10        ; flags = 0 (blocking)
    xor r8, r8
    xor r9, r9
    mov rax, 45         ; syscall: recvfrom
    syscall

    ; Null-terminate the username
    cmp rax, 0
    jle .use_default_name
    lea rsi, [client_names]
    add rsi, r13
    add rsi, rax        ; move to end of received data
    mov byte [rsi], 0   ; null terminate
    jmp .name_set

.use_default_name:
    ; If recv failed, use "Unknown"
    lea rdi, [client_names]
    add rdi, r13
    mov byte [rdi], 'U'
    mov byte [rdi + 1], 'n'
    mov byte [rdi + 2], 'k'
    mov byte [rdi + 3], 'n'
    mov byte [rdi + 4], 'o'
    mov byte [rdi + 5], 'w'
    mov byte [rdi + 6], 'n'
    mov byte [rdi + 7], 0

.name_set:
    ; Increment client count
    add qword [num_clients], 1

    ; Print connection message with username
    mov rsi, client_connected_msg
    mov rdx, client_connected_msg_len
    call print_string

    ; Print username
    lea rdi, [client_names]
    add rdi, r13
    call strlen
    mov rdx, rax
    lea rsi, [client_names]
    add rsi, r13
    call print_string

    ; Print newline
    mov rax, 1
    mov rdi, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall

.skip_add:
    pop r13
    pop r12
    pop rbx
    ret

remove_client:
    ; Input: rbx = client index to remove
    push rax
    push rcx
    push rsi
    push rdi
    push r12
    push r13

    ; Print disconnection message
    mov rsi, client_disconnected_msg
    mov rdx, client_disconnected_msg_len
    call print_string

    ; Print username
    imul r13, rbx, 64
    lea rdi, [client_names]
    add rdi, r13
    call strlen
    mov rdx, rax
    lea rsi, [client_names]
    add rsi, r13
    call print_string

    ; Print newline
    mov rax, 1
    mov rdi, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall

    ; Close the client socket
    mov rax, 3          ; syscall: close
    mov rsi, clients
    mov rdi, [rsi + rbx * 8]
    syscall

    ; Shift remaining clients down in both arrays
    mov rcx, rbx
    inc rcx             ; start from next client

.shift_loop:
    mov rax, [num_clients]
    cmp rcx, rax
    jge .shift_done

    ; Shift socket fd
    mov rsi, clients
    mov rdi, [rsi + rcx * 8]
    mov [rsi + (rcx - 1) * 8], rdi

    ; Shift username (copy 64 bytes)
    lea rsi, [client_names]
    imul r12, rcx, 64
    add rsi, r12
    lea rdi, [client_names]
    imul r13, rcx, 64
    sub r13, 64
    add rdi, r13

    push rcx
    mov rcx, 64
.copy_name:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .copy_name
    pop rcx

    inc rcx
    jmp .shift_loop

.shift_done:
    ; Decrement num_clients
    dec qword [num_clients]

    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

broadcast_message:
    ; Input: rsi = message, rdx = length, rdi = sender_index
    push rbx
    push r12
    push r13
    push r14

    mov r14, rsi        ; save message pointer
    mov r13, rdx        ; save message length
    mov r12, rdi        ; sender_index
    xor rbx, rbx        ; current client index

.broadcast_loop:
    mov rax, [num_clients]
    cmp rbx, rax
    jge .broadcast_done

    cmp rbx, r12        ; skip sender
    je .broadcast_next

    mov rax, clients
    mov rdi, [rax + rbx * 8]

    ; Send message using sendto syscall
    mov rsi, r14        ; message pointer
    mov rdx, r13        ; message length
    xor r10, r10        ; flags = 0
    xor r8, r8          ; dest_addr = NULL (connected socket)
    xor r9, r9          ; addrlen = 0
    mov rax, 44         ; syscall: sendto
    syscall

.broadcast_next:
    add rbx, 1
    jmp .broadcast_loop

.broadcast_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

process_clients:
    ; Receive from all clients and broadcast
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor rbx, rbx        ; current client index

.process_loop:
    mov rax, [num_clients]
    cmp rbx, rax
    jge .process_done

    mov rax, clients
    mov rdi, [rax + rbx * 8]

    ; Try to receive from this client using recvfrom
    lea rsi, [input_buffer]
    mov rdx, 1024       ; buffer size
    mov r10, 0x40       ; flags = MSG_DONTWAIT (non-blocking)
    xor r8, r8          ; src_addr = NULL
    xor r9, r9          ; addrlen = NULL
    mov rax, 45         ; syscall: recvfrom
    syscall

    ; Check for client disconnection (recv returned 0)
    cmp rax, 0
    je .client_disconnected

    ; Check for EAGAIN/EWOULDBLOCK (-11) which is normal for non-blocking
    cmp rax, -11
    je .process_next

    ; Check for other errors
    cmp rax, 0
    jl .client_disconnected

    ; Got a message
    mov r12, rax        ; save message length in r12

    ; Check if it's a /nick command
    cmp r12, 6
    jl .not_nick_cmd

    lea rsi, [input_buffer]
    lea rdi, [nick_command]
    mov rcx, nick_command_len
.check_nick:
    cmp rcx, 0
    je .is_nick_cmd
    mov al, [rsi]
    mov ah, [rdi]
    cmp al, ah
    jne .not_nick_cmd
    inc rsi
    inc rdi
    dec rcx
    jmp .check_nick

.is_nick_cmd:
    ; Update the username
    ; rsi now points to the new username (after "/nick ")
    imul r13, rbx, 64
    lea rdi, [client_names]
    add rdi, r13

    ; Calculate new username length
    mov rcx, r12
    sub rcx, nick_command_len
    cmp rcx, 63
    jle .copy_nick
    mov rcx, 63     ; max 63 chars

.copy_nick:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .copy_nick
    mov byte [rdi], 0   ; null terminate

    jmp .process_next

.not_nick_cmd:
    ; Format message as "[username]: message"
    lea rdi, [formatted_msg_buffer]

    ; Add "["
    mov byte [rdi], '['
    inc rdi

    ; Copy username
    imul r13, rbx, 64
    lea rsi, [client_names]
    add rsi, r13
.copy_username:
    mov al, [rsi]
    cmp al, 0
    je .done_username
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .copy_username

.done_username:
    ; Add "]: "
    mov byte [rdi], ']'
    inc rdi
    mov byte [rdi], ':'
    inc rdi
    mov byte [rdi], ' '
    inc rdi

    ; Copy message
    lea rsi, [input_buffer]
    mov rcx, r12
.copy_message:
    cmp rcx, 0
    je .done_message
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .copy_message

.done_message:
    ; Calculate total length
    lea rax, [formatted_msg_buffer]
    sub rdi, rax
    mov r14, rdi        ; r14 = formatted message length

    ; Broadcast the formatted message
    lea rsi, [formatted_msg_buffer]
    mov rdx, r14        ; message length
    mov rdi, rbx        ; sender index
    call broadcast_message

    jmp .process_next

.client_disconnected:
    ; Remove the client (rbx contains the index)
    call remove_client
    ; Don't increment rbx because clients shifted down
    jmp .process_loop

.process_next:
    add rbx, 1
    jmp .process_loop

.process_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

main_loop:
    ; Set up timespec structure (0.05 seconds = 50,000,000 nanoseconds)
    mov qword [timespec_req], 0             ; tv_sec = 0
    mov qword [timespec_req + 8], 50000000  ; tv_nsec = 50,000,000
    
    mov rax, 35                          ; syscall: nanosleep
    lea rdi, [timespec_req]              ; pointer to timespec_req
    xor rsi, rsi                         ; NULL for remainder
    syscall

    ; Try to accept a new connection
    mov rax, 43         ; syscall: accept
    mov rdi, [server_sockfd]
    xor rsi, rsi        ; NULL for addr
    xor rdx, rdx        ; NULL for addrlen
    syscall

    cmp rax, 0
    jl .no_new_connection

    ; Successfully accepted a new client
    mov rdi, rax
    call add_client

.no_new_connection:
    ; Process existing clients (always do this, regardless of accept result)
    call process_clients
    jmp main_loop

_start:
    push rbp
    mov rbp, rsp
    sub rsp, 16              ; Align stack to 16-byte boundary

    ; Parse command-line arguments
    ; argc is at [rbp + 8], argv is at [rbp + 16]
    mov rax, [rbp + 8]       ; argc

    ; Set defaults
    xor eax, eax
    mov [bind_ip], eax
    mov ax, word [default_port]
    mov [bind_port], ax

    ; Check if argc >= 2 (has IP argument)
    mov rax, [rbp + 8]
    cmp rax, 2
    jl .args_parsed

    ; Parse IP address (stores directly in bind_ip)
    mov rdi, [rbp + 24]      ; argv[1] = IP string
    call parse_ip

    ; Check if argc >= 3 (has port argument)
    mov rax, [rbp + 8]
    cmp rax, 3
    jl .args_parsed

    ; Parse port number
    mov rdi, [rbp + 32]      ; argv[2] = port string
    call atoi
    mov [bind_port], ax

.args_parsed:
    ; Create a TCP socket
    mov rax, 41          ; syscall: socket
    mov rdi, 2           ; domain: AF_INET
    mov rsi, 1           ; type: SOCK_STREAM
    mov rdx, 0           ; protocol: IPPROTO_IP
    syscall

    cmp rax, 0
    jl socket_error

    mov [server_sockfd], rax

    ; Prepare the sockaddr_in structure
    xor rax, rax
    mov [address], rax
    mov [address + 8], rax

    mov word [address], 2            ; AF_INET (sin_family)

    ; Use parsed port
    movzx rdi, word [bind_port]
    call htons
    mov word [address + 2], ax       ; sin_port (network byte order)

    ; Use parsed IP
    mov eax, [bind_ip]
    mov dword [address + 4], eax

    ; Bind the socket
    mov rax, 49          ; syscall: bind
    mov rdi, [server_sockfd]
    lea rsi, [address]
    mov rdx, 16          ; size of sockaddr_in
    syscall

    cmp rax, 0
    jl socket_bind_error

    ; Listen on the socket
    mov rax, 50
    mov rdi, [server_sockfd]
    mov rsi, 5           ; backlog
    syscall

    cmp rax, 0
    jl socket_listen_error

    ; Set socket to non-blocking mode using fcntl
    mov rax, 72         ; syscall: fcntl
    mov rdi, [server_sockfd]
    mov rsi, 4          ; F_SETFL (set file status flags)
    mov rdx, 2048       ; O_NONBLOCK = 2048 (0x800)
    syscall

    ; Initialize num_clients to 0
    mov qword [num_clients], 0

    ; Print startup message with actual IP and port
    mov rsi, server_start_msg
    mov rdx, server_start_msg_len
    call print_string

    ; Print IP address in dotted notation
    lea rsi, [server_info_buffer]
    mov rdi, rsi

    ; Convert each octet
    movzx rax, byte [bind_ip]
    call print_number_to_buffer
    mov byte [rdi], '.'
    inc rdi

    movzx rax, byte [bind_ip + 1]
    call print_number_to_buffer
    mov byte [rdi], '.'
    inc rdi

    movzx rax, byte [bind_ip + 2]
    call print_number_to_buffer
    mov byte [rdi], '.'
    inc rdi

    movzx rax, byte [bind_ip + 3]
    call print_number_to_buffer
    mov byte [rdi], ':'
    inc rdi

    ; Print port
    movzx rax, word [bind_port]
    call print_number_to_buffer

    ; Calculate length and print
    lea rax, [server_info_buffer]
    sub rdi, rax
    mov rdx, rdi
    lea rsi, [server_info_buffer]
    call print_string

    ; Print newline
    mov rax, 1
    mov rdi, 1
    lea rsi, [newline]
    mov rdx, 1
    syscall

    jmp main_loop

    ; Close the socket before exiting
    mov rax, 3
    mov rdi, [server_sockfd]
    syscall

    ; Exit syscall
    mov rax, 60
    xor rdi, rdi
    syscall
