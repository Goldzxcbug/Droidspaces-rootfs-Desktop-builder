#define _GNU_SOURCE
/*
 * fnos-appcenter-perm.c — 轻量级 inotify 守护进程（纯 C，无 Python 依赖）
 *
 * 在没有飞牛私有 trimacl 内核特性的 Android/主线内核中，存储卷按标准
 * POSIX 权限检查：
 *   1. /volN/appcenter-downloads 默认 0750 (root:root)，且社区 App 解包出的
 *      *-tpk 目录常为 0644，导致降权后的社区 App 用户无法执行 cmd/install_init。
 *   2. /volN/@appshare 默认 0000 (root:root)，导致社区 App 启动时无法穿越
 *      进入自己的 /volN/@appshare/<app> (0700) 数据目录。
 *
 * 本进程通过 Linux inotify 实时监听 /vol*、appcenter-downloads 与 @appshare，
 * 仅在缺少所需权限位时补齐 mode，空闲时阻塞在 poll()，零 CPU 占用且常驻内存极低。
 */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_WATCHES 512
#define WATCH_MASK (IN_CREATE | IN_MOVED_TO | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF)

enum watch_kind {
	KIND_VOL = 1,
	KIND_DL = 2,
	KIND_PKG = 3,
	KIND_APPSHARE = 4,
};

struct watch_entry {
	int wd;
	enum watch_kind kind;
	char path[PATH_MAX];
};

static volatile sig_atomic_t g_running = 1;
static struct watch_entry g_watches[MAX_WATCHES];
static size_t g_watch_count = 0;

static void handle_signal(int sig)
{
	(void)sig;
	g_running = 0;
}

static bool is_vol_name(const char *name)
{
	const char *p;

	if (strncmp(name, "vol", 3) != 0 || !isdigit((unsigned char)name[3]))
		return false;
	for (p = name + 3; *p; p++) {
		if (!isdigit((unsigned char)*p))
			return false;
	}
	return true;
}

static bool is_dir_nofollow(const char *path)
{
	struct stat st;

	return lstat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static bool ensure_dir_bits(const char *path, mode_t need_bits)
{
	struct stat st;
	mode_t cur, target;

	if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode))
		return false;

	cur = st.st_mode & 07777;
	target = cur | need_bits;
	if (target != cur) {
		if (chmod(path, target) != 0)
			return false;
	}
	return true;
}

static void fix_tree_dirs(const char *root, int max_depth)
{
	DIR *dir;
	struct dirent *ent;
	char child[PATH_MAX];

	if (!ensure_dir_bits(root, 0111) || max_depth <= 0)
		return;

	dir = opendir(root);
	if (!dir)
		return;

	while ((ent = readdir(dir)) != NULL) {
		if (ent->d_name[0] == '.' &&
		    (ent->d_name[1] == '\0' ||
		     (ent->d_name[1] == '.' && ent->d_name[2] == '\0')))
			continue;
		if (snprintf(child, sizeof(child), "%s/%s", root, ent->d_name) >= (int)sizeof(child))
			continue;
		if (is_dir_nofollow(child))
			fix_tree_dirs(child, max_depth - 1);
	}
	closedir(dir);
}

static struct watch_entry *find_watch_by_wd(int wd)
{
	for (size_t i = 0; i < g_watch_count; i++) {
		if (g_watches[i].wd == wd)
			return &g_watches[i];
	}
	return NULL;
}

static struct watch_entry *find_watch_by_path(const char *path)
{
	for (size_t i = 0; i < g_watch_count; i++) {
		if (strcmp(g_watches[i].path, path) == 0)
			return &g_watches[i];
	}
	return NULL;
}

static void drop_watch_index(size_t idx)
{
	if (idx >= g_watch_count)
		return;
	if (idx + 1 < g_watch_count)
		g_watches[idx] = g_watches[g_watch_count - 1];
	g_watch_count--;
}

static void drop_watch_by_wd(int wd)
{
	for (size_t i = 0; i < g_watch_count; i++) {
		if (g_watches[i].wd == wd) {
			drop_watch_index(i);
			return;
		}
	}
}

static void add_watch(int fd, const char *path, enum watch_kind kind)
{
	int wd;
	struct watch_entry *existing;

	if (find_watch_by_path(path) != NULL)
		return;

	wd = inotify_add_watch(fd, path, WATCH_MASK);
	if (wd < 0)
		return;

	existing = find_watch_by_wd(wd);
	if (existing) {
		existing->kind = kind;
		snprintf(existing->path, sizeof(existing->path), "%s", path);
		return;
	}

	if (g_watch_count >= MAX_WATCHES)
		return;

	g_watches[g_watch_count].wd = wd;
	g_watches[g_watch_count].kind = kind;
	snprintf(g_watches[g_watch_count].path, sizeof(g_watches[g_watch_count].path), "%s", path);
	g_watch_count++;
}

static void attach_downloads_dir(int fd, const char *dl_dir)
{
	DIR *dir;
	struct dirent *ent;
	char child[PATH_MAX];

	ensure_dir_bits(dl_dir, 0111);
	add_watch(fd, dl_dir, KIND_DL);

	dir = opendir(dl_dir);
	if (!dir)
		return;

	while ((ent = readdir(dir)) != NULL) {
		if (ent->d_name[0] == '.' &&
		    (ent->d_name[1] == '\0' ||
		     (ent->d_name[1] == '.' && ent->d_name[2] == '\0')))
			continue;
		if (snprintf(child, sizeof(child), "%s/%s", dl_dir, ent->d_name) >= (int)sizeof(child))
			continue;
		if (is_dir_nofollow(child)) {
			fix_tree_dirs(child, 3);
			add_watch(fd, child, KIND_PKG);
		}
	}
	closedir(dir);
}

static void attach_appshare_dir(int fd, const char *share_dir)
{
	DIR *dir;
	struct dirent *ent;
	char child[PATH_MAX];

	ensure_dir_bits(share_dir, 0751);
	add_watch(fd, share_dir, KIND_APPSHARE);

	dir = opendir(share_dir);
	if (!dir)
		return;

	while ((ent = readdir(dir)) != NULL) {
		if (ent->d_name[0] == '.' &&
		    (ent->d_name[1] == '\0' ||
		     (ent->d_name[1] == '.' && ent->d_name[2] == '\0')))
			continue;
		if (snprintf(child, sizeof(child), "%s/%s", share_dir, ent->d_name) >= (int)sizeof(child))
			continue;
		if (is_dir_nofollow(child))
			ensure_dir_bits(child, 0700);
	}
	closedir(dir);
}

static void scan_volumes(int fd)
{
	DIR *root;
	struct dirent *ent;
	char vol_path[PATH_MAX];
	char sub_path[PATH_MAX];

	/* 清理已删除路径对应的 watch */
	for (size_t i = 0; i < g_watch_count; ) {
		if (!is_dir_nofollow(g_watches[i].path)) {
			inotify_rm_watch(fd, g_watches[i].wd);
			drop_watch_index(i);
		} else {
			i++;
		}
	}

	root = opendir("/");
	if (!root)
		return;

	while ((ent = readdir(root)) != NULL) {
		if (!is_vol_name(ent->d_name))
			continue;
		if (snprintf(vol_path, sizeof(vol_path), "/%s", ent->d_name) >= (int)sizeof(vol_path))
			continue;
		if (!is_dir_nofollow(vol_path))
			continue;

		add_watch(fd, vol_path, KIND_VOL);

		if (snprintf(sub_path, sizeof(sub_path), "%s/appcenter-downloads", vol_path) < (int)sizeof(sub_path) &&
		    is_dir_nofollow(sub_path)) {
			attach_downloads_dir(fd, sub_path);
		}
		if (snprintf(sub_path, sizeof(sub_path), "%s/@appshare", vol_path) < (int)sizeof(sub_path) &&
		    is_dir_nofollow(sub_path)) {
			attach_appshare_dir(fd, sub_path);
		}
	}
	closedir(root);
}

static void handle_event(int fd, const struct inotify_event *ev)
{
	struct watch_entry *entry;
	const char *name;
	char child[PATH_MAX];
	char base[PATH_MAX];
	enum watch_kind kind;

	if (ev->mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF)) {
		drop_watch_by_wd(ev->wd);
		return;
	}

	entry = find_watch_by_wd(ev->wd);
	if (!entry)
		return;

	kind = entry->kind;
	snprintf(base, sizeof(base), "%s", entry->path);
	name = (ev->len > 0) ? ev->name : "";

	if (kind == KIND_VOL) {
		if (strcmp(name, "appcenter-downloads") == 0) {
			if (snprintf(child, sizeof(child), "%s/%s", base, name) < (int)sizeof(child) &&
			    is_dir_nofollow(child))
				attach_downloads_dir(fd, child);
		} else if (strcmp(name, "@appshare") == 0) {
			if (snprintf(child, sizeof(child), "%s/%s", base, name) < (int)sizeof(child) &&
			    is_dir_nofollow(child))
				attach_appshare_dir(fd, child);
		}
		return;
	}

	if (kind == KIND_APPSHARE) {
		if (name[0] == '\0') {
			ensure_dir_bits(base, 0751);
			return;
		}
		if (snprintf(child, sizeof(child), "%s/%s", base, name) < (int)sizeof(child) &&
		    ((ev->mask & IN_ISDIR) || is_dir_nofollow(child)))
			ensure_dir_bits(child, 0700);
		return;
	}

	if (kind == KIND_DL) {
		if (name[0] == '\0') {
			ensure_dir_bits(base, 0111);
			return;
		}
		if (snprintf(child, sizeof(child), "%s/%s", base, name) < (int)sizeof(child) &&
		    ((ev->mask & IN_ISDIR) || is_dir_nofollow(child))) {
			fix_tree_dirs(child, 3);
			add_watch(fd, child, KIND_PKG);
		}
		return;
	}

	if (kind == KIND_PKG) {
		if (name[0] == '\0') {
			ensure_dir_bits(base, 0111);
			return;
		}
		if (snprintf(child, sizeof(child), "%s/%s", base, name) < (int)sizeof(child) &&
		    ((ev->mask & IN_ISDIR) || is_dir_nofollow(child)))
			fix_tree_dirs(child, 2);
	}
}

static void drain_events(int fd)
{
	char buf[65536] __attribute__((aligned(__alignof__(struct inotify_event))));
	ssize_t len;

	for (;;) {
		len = read(fd, buf, sizeof(buf));
		if (len < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				break;
			if (errno == EINTR)
				continue;
			break;
		}
		if (len == 0)
			break;

		for (char *ptr = buf; ptr < buf + len; ) {
			const struct inotify_event *ev = (const struct inotify_event *)ptr;
			handle_event(fd, ev);
			ptr += sizeof(*ev) + ev->len;
		}
	}
}

int main(void)
{
	int fd;
	struct pollfd pfd;

	signal(SIGTERM, handle_signal);
	signal(SIGINT, handle_signal);

	fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (fd < 0) {
		perror("inotify_init1");
		return 1;
	}

	scan_volumes(fd);

	pfd.fd = fd;
	pfd.events = POLLIN;

	while (g_running) {
		int ret = poll(&pfd, 1, 5000);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (ret > 0 && (pfd.revents & POLLIN)) {
			drain_events(fd);
		} else {
			scan_volumes(fd);
		}
	}

	close(fd);
	return 0;
}
