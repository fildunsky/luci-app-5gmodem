/*
 * 5gmodem-atd - слушатель URC на запасном AT-порту модема.
 *
 * Зачем. Обрыв сессии/регистрации мы узнаём опросом sessionwatch раз в ~30 c.
 * Модем же сообщает о событиях сам и сразу - незапрошенными строками (URC:
 * +CGEV, +CEREG, ^SIMST, NO CARRIER...). Демон держит порт открытым, читает
 * строки и передаёт их скрипту-диспетчеру - реакция <1 c вместо круга опроса.
 *
 * Почему ЗАПАСНОЙ порт. tty отдаёт данные тому, кто читает: постоянный
 * читатель на рабочем порту крал бы ответы у sms_tool/gcom (тот самый класс
 * коллизий, ради которого существует atlock.sh). URC же у модемов вещаются во
 * ВСЕ AT-порты, поэтому слушатель живёт на порту, которым никто не пользуется,
 * и не трогает ничего чужого. Порт выбирает init-скрипт (см. spare_at_port).
 *
 * Идеи (очередь end-flag'ов, колбэки по префиксу) - из ubus_at_daemon QModem;
 * код свой: один поток, poll(2), ноль внешних зависимостей. ubus-методы и
 * канал sendat - фаза 2, когда через демона поедет и опрос метрик.
 *
 * Выход при ошибке порта - штатный путь: модем переперечислился, procd
 * перезапустит службу, init заново найдёт порт.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <termios.h>
#include <poll.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <signal.h>
#include <syslog.h>

#define LINE_MAX_LEN 2048
/* Предохранитель от шторма: больше N запусков скрипта за окно - строки только
   в журнал. Модем в цикле переregистрации может сыпать URC десятками. */
#define SPAWN_WINDOW_SEC 60
#define SPAWN_MAX_PER_WINDOW 30

static const char *g_dev = NULL;
static const char *g_script = NULL;
#define MAX_INIT_CMDS 8
static const char *g_init[MAX_INIT_CMDS];
static int g_init_n = 0;

static void die(const char *msg)
{
	syslog(LOG_ERR, "%s: %s (%s)", g_dev ? g_dev : "atd", msg, strerror(errno));
	exit(1);
}

static int open_port(const char *dev)
{
	int fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0)
		die("не открыть порт");
	struct termios t;
	if (tcgetattr(fd, &t) < 0)
		die("tcgetattr");
	/* ЭКСКЛЮЗИВНОСТЬ ПОРТА. Два демона на одном tty дерутся за чтение: URC
	   достаётся тому, кто успел, - и уходит «не тому». Гонка реальна: hotplug
	   при переэнумерации перезапускает службу, пока прежний экземпляр ещё жив.
	   flock на самом fd устройства (не на отдельном lock-файле, как atlock.sh)
	   пускает РОВНО ОДНОГО слушателя: второй получает EWOULDBLOCK и уходит с
	   кодом 0 - штатно, без respawn-шторма procd. sms_tool/gcom берут порт
	   через свой lock-файл atlock, а не flock узла, - им этот замок не мешает. */
	if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
		if (errno == EWOULDBLOCK) {
			syslog(LOG_NOTICE, "%s уже слушает другой экземпляр - выхожу", dev);
			exit(0);
		}
		die("flock");
	}
	cfmakeraw(&t);
	/* CLOCAL: без него open/read зависят от DCD, которого у USB-ACM нет;
	   CREAD обязателен, иначе приёма не будет вовсе. */
	t.c_cflag |= CLOCAL | CREAD;
	cfsetispeed(&t, B115200);
	cfsetospeed(&t, B115200);
	/* Читаем сколько есть, без межбайтовых таймаутов - нарезкой на строки
	   занимается наш буфер. */
	t.c_cc[VMIN] = 0;
	t.c_cc[VTIME] = 0;
	if (tcsetattr(fd, TCSANOW, &t) < 0)
		die("tcsetattr");
	tcflush(fd, TCIFLUSH);
	return fd;
}

static int spawn_budget_ok(void)
{
	static time_t win_start;
	static int win_count;
	time_t now = time(NULL);
	if (now - win_start >= SPAWN_WINDOW_SEC) {
		win_start = now;
		win_count = 0;
	}
	if (win_count >= SPAWN_MAX_PER_WINDOW)
		return 0;
	win_count++;
	return 1;
}

static void handle_line(const char *line)
{
	/* Пустые строки и голое эхо не интересны. */
	if (line[0] == '\0')
		return;
	syslog(LOG_INFO, "URC %s: %s", g_dev, line);
	if (!g_script)
		return;
	if (!spawn_budget_ok()) {
		syslog(LOG_WARNING, "шторм URC на %s - скрипт пропущен", g_dev);
		return;
	}
	pid_t pid = fork();
	if (pid < 0)
		return;
	if (pid == 0) {
		/* Порт ребёнку не нужен и не должен пережить exec: висящий fd
		   держал бы устройство после переэнумерации. */
		int devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0) {
			dup2(devnull, 0);
			dup2(devnull, 1);
			dup2(devnull, 2);
		}
		execl("/bin/sh", "sh", g_script, g_dev, line, (char *)NULL);
		_exit(127);
	}
}

int main(int argc, char **argv)
{
	int opt;
	while ((opt = getopt(argc, argv, "d:s:i:")) != -1) {
		switch (opt) {
		case 'd': g_dev = optarg; break;
		case 's': g_script = optarg; break;
		case 'i':
			if (g_init_n < MAX_INIT_CMDS)
				g_init[g_init_n++] = optarg;
			break;
		default:
			fprintf(stderr, "usage: %s -d /dev/ttyUSBx [-s handler.sh] [-i ATcmd]...\n", argv[0]);
			return 2;
		}
	}
	if (!g_dev) {
		fprintf(stderr, "usage: %s -d /dev/ttyUSBx [-s handler.sh] [-i ATcmd]...\n", argv[0]);
		return 2;
	}
	openlog("5gmodem-atd", LOG_PID, LOG_DAEMON);
	/* Дети пожинаются автоматически - зомби от скриптов не копятся. */
	signal(SIGCHLD, SIG_IGN);

	int fd = open_port(g_dev);
	/* Подписки на отчёты (+CGEREP, +CEREG=2...) действуют НА ТОМ ПОРТУ, где
	   их попросили - включаем на своём. Ответы (OK) придут в общий поток и
	   просто попадут в журнал. */
	for (int i = 0; i < g_init_n; i++) {
		char cmd[256];
		int m = snprintf(cmd, sizeof(cmd), "%s\r\n", g_init[i]);
		if (m > 0 && m < (int)sizeof(cmd)) {
			if (write(fd, cmd, m) < 0)
				syslog(LOG_WARNING, "init «%s»: %s", g_init[i], strerror(errno));
			/* пауза, чтобы модем не склеил команды */
			usleep(300000);
		}
	}
	syslog(LOG_NOTICE, "слушаю URC на %s%s%s", g_dev,
	       g_script ? ", скрипт " : "", g_script ? g_script : "");

	char buf[LINE_MAX_LEN];
	size_t len = 0;
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	for (;;) {
		int rc = poll(&pfd, 1, -1);
		if (rc < 0) {
			if (errno == EINTR)
				continue;
			die("poll");
		}
		if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))
			die("порт пропал");
		char chunk[512];
		ssize_t n = read(fd, chunk, sizeof(chunk));
		if (n < 0) {
			if (errno == EAGAIN || errno == EINTR)
				continue;
			die("read");
		}
		if (n == 0) {
			/* VMIN=0: нулевое чтение = «данных нет» (гонка с poll или
			   сосед успел забрать байты) - это не конец порта. Настоящую
			   пропажу устройства ловят POLLERR/POLLHUP и ошибки read. */
			continue;
		}
		for (ssize_t i = 0; i < n; i++) {
			char c = chunk[i];
			if (c == '\r' || c == '\n') {
				buf[len] = '\0';
				handle_line(buf);
				len = 0;
			} else if (len < LINE_MAX_LEN - 1) {
				buf[len++] = c;
			}
			/* Строка длиннее буфера обрезается - URC такими не бывают,
			   а бинарный мусор с порта не должен нас ронять. */
		}
	}
}
