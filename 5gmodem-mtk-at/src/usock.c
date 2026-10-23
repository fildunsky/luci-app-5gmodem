#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>

int main(int argc, char **argv)
{
	struct sockaddr_un a;
	char buf[4096], acc[8192];
	int fd, n, ms, al = 0;
	fd_set rf;
	struct timeval tv;

	if (argc < 3)
		return 2;
	ms = argc > 3 ? atoi(argv[3]) : 3000;
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strncpy(a.sun_path, argv[1], sizeof(a.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
		perror("connect");
		return 1;
	}
	n = strlen(argv[2]);
	memcpy(buf, argv[2], n);
	buf[n++] = '\r';
	if (write(fd, buf, n) != n) {
		perror("write");
		return 1;
	}
	for (;;) {
		FD_ZERO(&rf);
		FD_SET(fd, &rf);
		tv.tv_sec = ms / 1000;
		tv.tv_usec = (ms % 1000) * 1000;
		if (select(fd + 1, &rf, NULL, NULL, &tv) <= 0)
			break;
		n = read(fd, buf, sizeof(buf));
		if (n <= 0)
			break;
		fwrite(buf, 1, n, stdout);
		fflush(stdout);
		if (al + n < (int)sizeof(acc) - 1) {
			memcpy(acc + al, buf, n);
			al += n;
			acc[al] = 0;
			if (strstr(acc, "\nOK") || strstr(acc, "ERROR"))
				break;
		}
		ms = 1000;
	}
	close(fd);
	return 0;
}
