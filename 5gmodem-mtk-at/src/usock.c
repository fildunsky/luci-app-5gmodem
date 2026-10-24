#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <termios.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <sys/select.h>

#define MUX_SOCK "/var/run/5gm-atci.sock"
#define MAXCL 8

static const char *mux_path(void)
{
	const char *p = getenv("USOCK_MUX");

	return p && *p ? p : MUX_SOCK;
}

static int sock_open(const char *path)
{
	struct sockaddr_un a;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);

	if (fd < 0)
		return -1;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static int sock_listen(const char *path)
{
	struct sockaddr_un a;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);

	if (fd < 0)
		return -1;
	unlink(path);
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(fd, MAXCL) < 0) {
		close(fd);
		return -1;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	return fd;
}

static int final_result(const char *s)
{
	return strstr(s, "\nOK") || strstr(s, "OK\r") == s || strstr(s, "ERROR") ||
		strstr(s, "NO CARRIER");
}

static int write_all(int fd, const char *b, int n)
{
	while (n > 0) {
		int w = write(fd, b, n);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN)
				return 0;
			return -1;
		}
		b += w;
		n -= w;
	}
	return 0;
}

static int one_shot(int argc, char **argv)
{
	char buf[4096], acc[8192];
	int fd, n, ms, al = 0;
	fd_set rf;
	struct timeval tv;

	ms = argc > 3 ? atoi(argv[3]) : 3000;
	fd = -1;
	if (!getenv("USOCK_DIRECT") && access(mux_path(), F_OK) == 0)
		fd = sock_open(mux_path());
	if (fd < 0)
		fd = sock_open(argv[1]);
	if (fd < 0) {
		perror("connect");
		return 1;
	}
	n = strlen(argv[2]);
	if (n > (int)sizeof(buf) - 2)
		n = sizeof(buf) - 2;
	memcpy(buf, argv[2], n);
	buf[n++] = '\r';
	if (write_all(fd, buf, n) < 0) {
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

static int pty_make(const char *link, int *slave)
{
	struct termios t;
	unsigned int pn;
	int m = posix_openpt(O_RDWR | O_NOCTTY);

	if (m < 0 || grantpt(m) < 0 || unlockpt(m) < 0 || ioctl(m, TIOCGPTN, &pn) < 0)
		return -1;
	unlink(link);
	*slave = -1;
	if (symlink(ptsname(m), link) == 0)
		*slave = open(link, O_RDWR | O_NOCTTY);
	if (*slave < 0) {
		unlink(link);
		if (mknod(link, S_IFCHR | 0660, makedev(136 + pn / 256, pn % 256)) < 0)
			return -1;
		*slave = open(link, O_RDWR | O_NOCTTY);
	}
	if (*slave < 0)
		return -1;
	fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK);
	if (tcgetattr(*slave, &t) == 0) {
		cfmakeraw(&t);
		tcsetattr(*slave, TCSANOW, &t);
	}
	return m;
}

struct src {
	int fd;
	int pty;
	char in[8192];
	int il;
};

static void drop_owner(struct src *s, int *owner, int *prompt)
{
	if (*owner >= 0 && !s[*owner].pty) {
		close(s[*owner].fd);
		s[*owner].fd = -1;
	}
	*owner = -1;
	*prompt = 0;
}

static int bridge(const char *spath, const char *link)
{
	struct src s[MAXCL + 1];
	char buf[4096], acc[8192];
	int m, sl, ls, r = -1, owner = -1, prompt = 0, al = 0, n, i, j, mx;
	time_t last = 0;
	fd_set rf;
	struct timeval tv;

	signal(SIGPIPE, SIG_IGN);
	m = pty_make(link, &sl);
	if (m < 0) {
		perror("pty");
		return 1;
	}
	ls = sock_listen(mux_path());
	for (i = 0; i <= MAXCL; i++)
		s[i].fd = -1;
	s[0].fd = m;
	s[0].pty = 1;
	s[0].il = 0;
	for (;;) {
		FD_ZERO(&rf);
		mx = -1;
		if (owner < 0) {
			for (i = 0; i <= MAXCL; i++)
				if (s[i].fd >= 0) {
					FD_SET(s[i].fd, &rf);
					if (s[i].fd > mx)
						mx = s[i].fd;
				}
			if (ls >= 0) {
				FD_SET(ls, &rf);
				if (ls > mx)
					mx = ls;
			}
		} else if (prompt) {
			FD_SET(s[owner].fd, &rf);
			if (s[owner].fd > mx)
				mx = s[owner].fd;
		}
		if (r >= 0) {
			FD_SET(r, &rf);
			if (r > mx)
				mx = r;
		}
		tv.tv_sec = 1;
		tv.tv_usec = 0;
		n = select(mx + 1, &rf, NULL, NULL, &tv);
		if (n < 0 && errno != EINTR)
			break;
		if (owner >= 0 && time(NULL) - last > 30) {
			drop_owner(s, &owner, &prompt);
			al = 0;
		}
		if (n <= 0)
			continue;
		if (r >= 0 && FD_ISSET(r, &rf)) {
			n = read(r, buf, sizeof(buf));
			if (n <= 0) {
				close(r);
				r = -1;
				if (owner >= 0) {
					write_all(s[owner].fd, "\r\nERROR\r\n", 9);
					drop_owner(s, &owner, &prompt);
				}
				continue;
			}
			if (owner < 0)
				continue;
			write_all(s[owner].fd, buf, n);
			last = time(NULL);
			if (al + n < (int)sizeof(acc) - 1) {
				memcpy(acc + al, buf, n);
				al += n;
				acc[al] = 0;
			} else {
				al = 0;
			}
			if (strstr(acc, "\n>")) {
				prompt = 1;
				al = 0;
			} else if (final_result(acc)) {
				drop_owner(s, &owner, &prompt);
				al = 0;
			}
			continue;
		}
		if (owner < 0 && ls >= 0 && FD_ISSET(ls, &rf)) {
			int c = accept(ls, NULL, NULL);

			if (c >= 0) {
				for (j = 1; j <= MAXCL && s[j].fd >= 0; j++)
					;
				if (j > MAXCL) {
					close(c);
				} else {
					s[j].fd = c;
					s[j].pty = 0;
					s[j].il = 0;
				}
			}
		}
		for (i = 0; i <= MAXCL && (owner < 0 || prompt); i++) {
			struct src *p = &s[i];

			if (p->fd < 0 || !FD_ISSET(p->fd, &rf))
				continue;
			if (owner >= 0 && owner != i)
				continue;
			n = read(p->fd, buf, sizeof(buf));
			if (n <= 0) {
				if (n < 0 && (errno == EAGAIN || errno == EINTR))
					continue;
				if (p->pty) {
					if (n < 0 && errno == EIO)
						usleep(100000);
					continue;
				}
				close(p->fd);
				p->fd = -1;
				if (owner == i) {
					owner = -1;
					prompt = 0;
				}
				continue;
			}
			for (j = 0; j < n; j++) {
				char c = buf[j];

				if (p->il < (int)sizeof(p->in) - 1)
					p->in[p->il++] = c;
				if (c != '\r' && c != '\n' && c != 0x1a && c != 0x1b)
					continue;
				if (p->il == 1) {
					p->il = 0;
					continue;
				}
				if (c == '\n' && !prompt) {
					p->il = 0;
					continue;
				}
				if (r < 0)
					r = sock_open(spath);
				if (r < 0) {
					write_all(p->fd, "\r\nERROR\r\n", 9);
					p->il = 0;
					continue;
				}
				if (p->pty && !prompt)
					tcflush(sl, TCIFLUSH);
				if (write_all(r, p->in, p->il) < 0) {
					close(r);
					r = -1;
					write_all(p->fd, "\r\nERROR\r\n", 9);
					p->il = 0;
					continue;
				}
				owner = i;
				if (c == 0x1a || c == 0x1b)
					prompt = 0;
				al = 0;
				last = time(NULL);
				p->il = 0;
				break;
			}
			if (owner >= 0)
				break;
		}
	}
	unlink(link);
	unlink(mux_path());
	return 1;
}

int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "-b"))
		return bridge(argv[2], argv[3]);
	if (argc < 3)
		return 2;
	return one_shot(argc, argv);
}
