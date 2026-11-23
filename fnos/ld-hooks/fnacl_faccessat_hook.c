#define _GNU_SOURCE
/*
 * fnacl_faccessat_hook.c 鈥?椋炵墰绉佹湁 syscall 鍏煎灞? *
 * 鑳屾櫙
 * ----
 * 椋炵墰鎶婄鏈夎涔夊杩涖€岃礋鏁颁吉 dirfd銆嶏細
 *     faccessat(-21586, struct_ptr, mode, flags)   // 鍙傛暟鏄?struct锛岄瀛楁涓鸿矾寰? *     unlinkat(-7125, "vol1/1000/music/x", 0)      // 鍙傛暟鏄矾寰勪覆锛堟牴鐩稿锛? *     renameat2 / statx / utimensat 绫讳技
 *
 * 椋炵墰鍐呮牳璇嗗埆杩欎簺浼?dirfd 骞舵寜 trimacl 鍒ゅ畾锛涗富绾垮唴鏍稿綋鐪熷疄 fd 鈫?EBADF(9)锛? * 浜庢槸鍒犻櫎/涓婁紶鐩綍/鏀瑰悕鍏ㄩ儴澶辫触銆? *
 * 閲嶈鍖哄垎锛堣俯杩囧潙锛? * ------------------
 * 鍙湁 faccessat 鐨勫弬鏁板彲鑳芥槸銆岀粨鏋勪綋鎸囬拡銆嶏紙libnperm 鐨勮皟鐢ㄧ害瀹氾級銆? * unlinkat / statx / utimensat / renameat2 鐨勭浜屼釜鍙傛暟**鎸?POSIX 涓€瀹氭槸
 * 璺緞瀛楃涓?*锛屼笉鑳藉仛鎸囬拡鐚滄祴 鈥斺€?鍚﹀垯涓枃/闈?ASCII 璺緞浼氳璇垽鎴愭寚閽堬紝
 * 瑙ｅ紩鐢ㄥ嚭鍨冨溇璺緞锛屽鑷?errno 4100銆屾枃浠舵垨鐩綍涓嶅瓨鍦ㄣ€嶃€? *
 * 鍋氭硶
 * ----
 * 浼?dirfd 鈫?鍙栫湡瀹炶矾寰勶紙faccessat 鐗规畩澶勭悊锛夆啋 杞粷瀵硅矾寰?鈫? * 鐢?AT_FDCWD 璋冪湡姝ｇ殑鍑芥暟銆俧accessat 鐨?mode/flags 杩樿娓呮礂锛屽洜涓洪鐗? * 澶瑰甫绉佹湁浣嶏紙濡?mode 閲岀殑 0x8锛夛紝鐩存帴閫忎紶浼氳 faccessat2 杩斿洖 EINVAL(22)銆? *
 * 缂栬瘧
 * ----
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -o fnacl_faccessat_hook.so \
 *       fnacl_faccessat_hook.c -ldl
 *
 * 鐢ㄦ硶
 * ----
 *   LD_PRELOAD=/opt/fnnas/fnacl_faccessat_hook.so
 *
 * 璋冭瘯
 * ----
 *   FNACL_LOG=1 鈫?姣忔浼?dirfd 璋冪敤鍐?/tmp/fnacl.log
 */

#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <stdint.h>

#include <linux/stat.h>

#define FNACL_PATH_MAX 4096

typedef int (*faccessat_fn)(int, const char *, int, int);
typedef int (*unlinkat_fn)(int, const char *, int);
typedef int (*renameat2_fn)(int, const char *, int, const char *, unsigned int);
typedef int (*statx_fn)(int, const char *, int, unsigned int, struct statx *);
typedef int (*utimensat_fn)(int, const char *, const struct timespec *, int);

static int logging_enabled(void)
{
	static int cached = -1;
	if (cached < 0) {
		const char *v = getenv("FNACL_LOG");
		cached = (v && (v[0] == '1' || v[0] == 'y' || v[0] == 'Y'));
	}
	return cached;
}

static void dbg(const char *fn, int dfd, const char *real, int ret, int err)
{
	FILE *f;

	if (!logging_enabled())
		return;
	f = fopen("/tmp/fnacl.log", "a");
	if (!f)
		return;
	fprintf(f, "%s dfd=%d real=%s ret=%d errno=%d\n",
		fn, dfd, real ? real : "(null)", ret, err);
	fclose(f);
}

/* 璐?dirfd 瑙嗕负浼?dirfd锛圓T_FDCWD == -100 瑕佹帓闄わ級 */
static int is_fake_dfd(int dfd)
{
	return dfd < 0 && dfd != AT_FDCWD;
}

/*
 * 鎶婂彲鑳界浉瀵圭殑璺緞杞垚缁濆璺緞锛屽啓鍏ョ嚎绋嬪眬閮ㄧ紦鍐层€? * 椋炵墰浼犵殑鏄牴鐩稿璺緞锛?vol1/1000/..."锛夛紝琛?'/' 鍗充负缁濆璺緞銆? */
static const char *to_abs(const char *s)
{
	static __thread char buf[FNACL_PATH_MAX];

	if (!s)
		return NULL;
	if (s[0] == '/')
		return s;
	if (strlen(s) + 2 > sizeof(buf))
		return s;
	buf[0] = '/';
	strncpy(buf + 1, s, sizeof(buf) - 2);
	buf[sizeof(buf) - 1] = 0;
	return buf;
}

/*
 * unlinkat / statx / utimensat / renameat2锛氬弬鏁颁竴瀹氭槸璺緞涓诧紝鐩存帴鐢ㄣ€? */
static const char *resolve_plain(const char *p)
{
	return to_abs(p);
}

/*
 * faccessat锛歭ibnperm 浼犵殑鏄粨鏋勪綋鎸囬拡锛岄瀛楁鎵嶆槸璺緞銆? * 鍒ゆ嵁锛氶瀛楄妭涓嶆槸 '/'锛屼笖瑙ｅ紩鐢ㄥ悗寰楀埌浠?'/' 寮€澶寸殑瀛楃涓?鈫?璁や负鏄?struct锛? * 鍚﹀垯褰撲綔鏅€氳矾寰勶紙杩欐牱涓枃绛夐潪 ASCII 璺緞涔熻兘姝ｇ‘淇濈暀锛夈€? */
/*
 * 判断 p 指向的内容是否"像一个用户态指针值"。
 *
 * 关键依据：arm64 用户态地址 < 2^48；而任意 8 字节可打印 ASCII
 * （路径首字节 0x20..0x7e）组成的值 ≥ 0x2020202020202020 ≈ 2.3e18，
 * 远大于 2^48 ≈ 2.8e14。所以可以直接用数值范围排除"路径被当指针"。
 *
 * 这条判据避免了把 "vol1/100" 当成地址 0x3030312f316c6f76 去解引用
 * 而触发 SIGSEGV（实测崩过一次）。
 */
static int looks_like_ptr(const char *p)
{
	uint64_t v;

	memcpy(&v, p, sizeof(v));
	return v > 0x1000ULL && v < 0x0001000000000000ULL;
}

static const char *resolve_faccessat(const char *p)
{
	const char *inner;

	if (!p)
		return p;
	if (p[0] == '/')
		return p;

	/* 只有数值上像用户态地址时，才当作 libnperm 的 struct 解引用 */
	if (looks_like_ptr(p)) {
		inner = *(const char * const *)p;
		if (inner && inner[0] == '/')
			return to_abs(inner);
	}

	return to_abs(p);
}

/* ---------------- faccessat ---------------- */

int faccessat(int dfd, const char *pathname, int mode, int flags)
{
	static faccessat_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (faccessat_fn)dlsym(RTLD_NEXT, "faccessat");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, mode, flags);

	real_path = resolve_faccessat(pathname);

	/* 娓呮礂椋炵墰绉佹湁浣嶏細mode 鍙暀浣?3 浣嶏紝flags 鍙暀鏍囧噯浣?*/
	mode  &= 7;
	flags &= (AT_SYMLINK_NOFOLLOW | AT_EACCESS | AT_EMPTY_PATH);

	ret = real(AT_FDCWD, real_path, mode, flags);
	saved = errno;
	dbg("faccessat", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- unlinkat ---------------- */

int unlinkat(int dfd, const char *pathname, int flags)
{
	static unlinkat_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (unlinkat_fn)dlsym(RTLD_NEXT, "unlinkat");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, flags);

	real_path = resolve_plain(pathname);
	ret = real(AT_FDCWD, real_path, flags);
	saved = errno;
	dbg("unlinkat", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- renameat2 ---------------- */

int renameat2(int olddfd, const char *oldname,
	      int newdfd, const char *newname, unsigned int flags)
{
	static renameat2_fn real;
	const char *n;
	char obuf[FNACL_PATH_MAX];
	int ret, saved;

	if (!real)
		real = (renameat2_fn)dlsym(RTLD_NEXT, "renameat2");

	if (!is_fake_dfd(olddfd) && !is_fake_dfd(newdfd))
		return real(olddfd, oldname, newdfd, newname, flags);

	/* resolve_plain 鍏辩敤绾跨▼缂撳啿锛屽厛鎷疯蛋鏃у悕 */
	snprintf(obuf, sizeof(obuf), "%s", resolve_plain(oldname) ?: "");
	n = resolve_plain(newname);

	ret = real(AT_FDCWD, obuf, AT_FDCWD, n, flags);
	saved = errno;
	dbg("renameat2", olddfd, n, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- statx ---------------- */

int statx(int dfd, const char *pathname, int flags, unsigned int mask,
	  struct statx *statxbuf)
{
	static statx_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (statx_fn)dlsym(RTLD_NEXT, "statx");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, flags, mask, statxbuf);

	real_path = resolve_plain(pathname);
	ret = real(AT_FDCWD, real_path, flags, mask, statxbuf);
	saved = errno;
	dbg("statx", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- utimensat ---------------- */

int utimensat(int dfd, const char *pathname, const struct timespec times[2],
	      int flags)
{
	static utimensat_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (utimensat_fn)dlsym(RTLD_NEXT, "utimensat");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, times, flags);

	real_path = resolve_plain(pathname);
	ret = real(AT_FDCWD, real_path, times, flags);
	saved = errno;
	dbg("utimensat", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}


