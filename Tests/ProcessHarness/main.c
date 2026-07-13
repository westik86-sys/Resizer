#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static int write_all(int descriptor, const void *bytes, size_t byte_count) {
    const uint8_t *cursor = bytes;
    size_t remaining = byte_count;

    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return 0;
}

static int write_text(int descriptor, const char *text) {
    return write_all(descriptor, text, strlen(text));
}

static int write_u32(int descriptor, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)((value >> 24) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)(value & 0xff),
    };
    return write_all(descriptor, bytes, sizeof(bytes));
}

struct flood_arguments {
    int descriptor;
    size_t byte_count;
    uint8_t byte;
    int uses_pattern;
};

static void *write_flood(void *raw_arguments) {
    struct flood_arguments *arguments = raw_arguments;
    uint8_t chunk[16 * 1024];
    if (!arguments->uses_pattern) {
        memset(chunk, arguments->byte, sizeof(chunk));
    }

    size_t remaining = arguments->byte_count;
    size_t offset = 0;
    while (remaining > 0) {
        size_t amount = remaining < sizeof(chunk) ? remaining : sizeof(chunk);
        if (arguments->uses_pattern) {
            for (size_t index = 0; index < amount; index += 1) {
                chunk[index] = (uint8_t)((offset + index) % 251);
            }
        }
        if (write_all(arguments->descriptor, chunk, amount) != 0) {
            return (void *)(intptr_t)1;
        }
        offset += amount;
        remaining -= amount;
    }
    return NULL;
}

static int run_flood(const char *byte_count_text) {
    char *end = NULL;
    unsigned long long parsed = strtoull(byte_count_text, &end, 10);
    if (end == byte_count_text || *end != '\0' || parsed > SIZE_MAX) {
        return 64;
    }

    struct flood_arguments standard_output = {
        .descriptor = STDOUT_FILENO,
        .byte_count = (size_t)parsed,
        .byte = 'O',
        .uses_pattern = 0,
    };
    struct flood_arguments standard_error = {
        .descriptor = STDERR_FILENO,
        .byte_count = (size_t)parsed,
        .byte = 0,
        .uses_pattern = 1,
    };
    pthread_t standard_output_thread;
    pthread_t standard_error_thread;

    if (pthread_create(
            &standard_output_thread,
            NULL,
            write_flood,
            &standard_output
        ) != 0) {
        return 70;
    }
    if (pthread_create(
            &standard_error_thread,
            NULL,
            write_flood,
            &standard_error
        ) != 0) {
        pthread_join(standard_output_thread, NULL);
        return 70;
    }

    void *standard_output_result = NULL;
    void *standard_error_result = NULL;
    pthread_join(standard_output_thread, &standard_output_result);
    pthread_join(standard_error_thread, &standard_error_result);
    return standard_output_result == NULL && standard_error_result == NULL
        ? 0
        : 74;
}

static int echo_arguments(int argument_count, char *arguments[]) {
    uint32_t count = argument_count > 2
        ? (uint32_t)(argument_count - 2)
        : 0;
    if (write_u32(STDOUT_FILENO, count) != 0) {
        return 74;
    }

    for (int index = 2; index < argument_count; index += 1) {
        size_t length = strlen(arguments[index]);
        if (length > UINT32_MAX
            || write_u32(STDOUT_FILENO, (uint32_t)length) != 0
            || write_all(STDOUT_FILENO, arguments[index], length) != 0) {
            return 74;
        }
    }
    return 0;
}

static int echo_environment(int argument_count, char *arguments[]) {
    uint32_t count = argument_count > 2
        ? (uint32_t)(argument_count - 2)
        : 0;
    if (write_u32(STDOUT_FILENO, count) != 0) {
        return 74;
    }

    for (int index = 2; index < argument_count; index += 1) {
        const char *value = getenv(arguments[index]);
        uint8_t present = value == NULL ? 0 : 1;
        if (write_all(STDOUT_FILENO, &present, sizeof(present)) != 0) {
            return 74;
        }
        if (value != NULL) {
            size_t length = strlen(value);
            if (length > UINT32_MAX
                || write_u32(STDOUT_FILENO, (uint32_t)length) != 0
                || write_all(STDOUT_FILENO, value, length) != 0) {
                return 74;
            }
        }
    }
    return 0;
}

static int write_ready(void) {
    char ready[64];
    int length = snprintf(ready, sizeof(ready), "READY:%d\n", getpid());
    if (length <= 0 || (size_t)length >= sizeof(ready)) {
        return -1;
    }
    return write_all(STDOUT_FILENO, ready, (size_t)length);
}

static int wait_for_q(void) {
    alarm(10);
    if (write_ready() != 0) {
        return 74;
    }

    uint8_t received[4096];
    size_t count = 0;
    while (count < sizeof(received)) {
        ssize_t amount = read(
            STDIN_FILENO,
            received + count,
            sizeof(received) - count
        );
        if (amount == 0) {
            break;
        }
        if (amount < 0) {
            if (errno == EINTR) {
                continue;
            }
            return 74;
        }
        count += (size_t)amount;
    }

    static const uint8_t expected[] = {'q', '\n'};
    if (count == sizeof(expected)
        && memcmp(received, expected, sizeof(expected)) == 0) {
        return 0;
    }
    return 42;
}

static int wait_while_ignoring(int ignore_terminate) {
    signal(SIGINT, SIG_IGN);
    if (ignore_terminate) {
        signal(SIGTERM, SIG_IGN);
    }
    alarm(10);
    if (write_ready() != 0) {
        return 74;
    }
    for (;;) {
        pause();
    }
}

static int delayed_eof(void) {
    pid_t holder = fork();
    if (holder < 0) {
        return 71;
    }
    if (holder == 0) {
        usleep(150 * 1000);
        write_text(STDOUT_FILENO, "stdout:after-parent-exit\n");
        write_text(STDERR_FILENO, "stderr:after-parent-exit\n");
        _exit(0);
    }

    write_text(STDOUT_FILENO, "stdout:parent-exit\n");
    write_text(STDERR_FILENO, "stderr:parent-exit\n");
    return 0;
}

static int race_exit(void) {
    alarm(10);
    if (write_ready() != 0) {
        return 74;
    }

    uint8_t buffer[64];
    for (;;) {
        ssize_t amount = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (amount == 0) {
            break;
        }
        if (amount < 0 && errno != EINTR) {
            return 74;
        }
    }
    usleep(30 * 1000);
    return 0;
}

static int close_pipes_and_wait(void) {
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    alarm(10);
    if (write_ready() != 0) {
        return 74;
    }
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    for (;;) {
        pause();
    }
}

int main(int argument_count, char *arguments[]) {
    if (argument_count < 2) {
        write_text(STDERR_FILENO, "missing mode\n");
        return 64;
    }

    const char *mode = arguments[1];
    if (strcmp(mode, "success") == 0) {
        write_text(STDOUT_FILENO, "stdout:success\n");
        write_text(STDERR_FILENO, "stderr:success\n");
        return 0;
    }
    if (strcmp(mode, "exit") == 0 && argument_count == 3) {
        char *end = NULL;
        long status = strtol(arguments[2], &end, 10);
        if (end == arguments[2] || *end != '\0' || status < 1 || status > 255) {
            return 64;
        }
        write_text(STDERR_FILENO, "requested nonzero exit\n");
        return (int)status;
    }
    if (strcmp(mode, "flood") == 0 && argument_count == 3) {
        alarm(10);
        return run_flood(arguments[2]);
    }
    if (strcmp(mode, "echo-arguments") == 0) {
        return echo_arguments(argument_count, arguments);
    }
    if (strcmp(mode, "echo-environment") == 0) {
        return echo_environment(argument_count, arguments);
    }
    if (strcmp(mode, "wait-for-q") == 0) {
        return wait_for_q();
    }
    if (strcmp(mode, "ignore-interrupt") == 0) {
        return wait_while_ignoring(0);
    }
    if (strcmp(mode, "ignore-signals") == 0) {
        return wait_while_ignoring(1);
    }
    if (strcmp(mode, "delayed-eof") == 0) {
        return delayed_eof();
    }
    if (strcmp(mode, "race-exit") == 0) {
        return race_exit();
    }
    if (strcmp(mode, "close-pipes-wait") == 0) {
        return close_pipes_and_wait();
    }

    write_text(STDERR_FILENO, "unknown mode\n");
    return 64;
}
