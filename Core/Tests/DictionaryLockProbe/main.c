#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <unistd.h>

enum {
    LockBlocked = 0,
    LockAvailable = 1,
    ProbeFailed = 2
};

int main(int argumentCount, char *arguments[]) {
    if (argumentCount != 2) {
        fputs("Expected the dictionary lock path.\n", stderr);
        return ProbeFailed;
    }
    int descriptor = open(arguments[1], O_RDWR);
    if (descriptor < 0) {
        perror("Opening the dictionary lock");
        return ProbeFailed;
    }
    int lockStatus = flock(descriptor, LOCK_EX | LOCK_NB);
    int lockError = errno;
    if (close(descriptor) != 0) {
        perror("Closing the dictionary lock");
        return ProbeFailed;
    }
    if (lockStatus == 0) {
        return LockAvailable;
    }
    if (lockError == EWOULDBLOCK || lockError == EAGAIN) {
        return LockBlocked;
    }
    errno = lockError;
    perror("Trying the dictionary lock");
    return ProbeFailed;
}
