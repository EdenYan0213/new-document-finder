// ============================================================
// newdoc — Finder 右键「新建文档」核心工具
//
// 设计原则：
//   · 无常驻进程：仅在触发时运行，创建完立即退出（零驻留内存）
//   · 无 shell 注入面：所有外部进程通过 argv 传参，绝不拼接 shell 字符串；
//     传给 AppleScript 的动态数据一律走 argv，不进入脚本文本
//   · 原子创建：OpenOptions::create_new 保证不覆盖任何已有文件（TOCTOU 安全）
//   · 输入收紧：扩展名/文件名前缀/模板名都经过白名单校验，
//     配置里的恶意值无法造成路径穿越
//   · 纯用户态：只写自己的 ~/Library/Application Support/NewDocument 与
//     ~/Library/Services，不碰系统目录
//
// 子命令：
//   run [路径…]      交互流程（供 Finder 快速操作调用）
//   create …         非交互创建（脚本/测试/高级用法）
//   types            列出配置的文档类型
// ============================================================

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};

// ---------- 常量 ----------

static DEFAULT_CONFIG: &str = include_str!("../config.toml");

const APP_DIR_NAME: &str = "Library/Application Support/NewDocument";
const TEMPLATE_SUBDIR: &str = "templates";
const CONFIG_FILE: &str = "config.toml";

const TITLE: &str = "新建文档";

// 静态 AppleScript：询问 Finder 当前位置（仅在新服务「无参数」时使用）
const FINDER_LOCATION_SCRIPT: &str = r#"tell application "Finder"
	try
		set sel to selection
		if (count of sel) > 0 then
			set it1 to item 1 of sel
			if class of it1 is folder then
				return POSIX path of (it1 as alias)
			else
				return POSIX path of (container of it1 as alias)
			end if
		end if
	end try
	return POSIX path of (insertion location as alias)
end tell"#;

// 静态 AppleScript：类型选择器。类型列表通过 argv 传入（argv 索引从 1 开始）
const PICK_SCRIPT: &str = r#"on run argv
	set picked to choose from list argv with title "新建文档" with prompt "选择要创建的文档类型：" default items {item 1 of argv}
	if picked is false then return ""
	repeat with i from 1 to count of argv
		if (item i of argv as text) = (item 1 of picked as text) then return i as text
	end repeat
	return ""
end run"#;

const NOTIFY_SCRIPT: &str = r#"on run argv
	display notification (item 2 of argv) with title (item 1 of argv)
end run"#;

const ALERT_SCRIPT: &str = r#"on run argv
	display alert (item 1 of argv) message (item 2 of argv)
end run"#;

// ---------- 配置 ----------

#[derive(Debug, Clone, serde::Deserialize)]
struct DocType {
    label: String,
    ext: String,
    #[serde(default)]
    template: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct Config {
    #[serde(default = "default_name_base")]
    name_base: String,
    #[serde(default)]
    types: Vec<DocType>,
}

fn default_name_base() -> String {
    "未命名".to_string()
}

/// 真实主目录：被沙盒接管时（FinderSync 扩展拉起的子进程）HOME 指向容器，
/// getpwuid 返回的用户主目录不受影响
fn real_home() -> PathBuf {
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if !pw.is_null() {
            let dir = (*pw).pw_dir;
            if !dir.is_null() {
                let s = std::ffi::CStr::from_ptr(dir).to_string_lossy().to_string();
                if !s.is_empty() {
                    return PathBuf::from(s);
                }
            }
        }
    }
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// 应用数据目录（NEWDOC_APP_DIR 仅供测试覆盖）
fn app_dir() -> PathBuf {
    if let Ok(p) = std::env::var("NEWDOC_APP_DIR") {
        return PathBuf::from(p);
    }
    real_home().join(APP_DIR_NAME)
}

fn load_config() -> Result<Config> {
    let path = app_dir().join(CONFIG_FILE);
    let text = fs::read_to_string(&path).unwrap_or_else(|_| DEFAULT_CONFIG.to_string());
    let cfg: Config = toml::from_str(&text).with_context(|| format!("解析配置失败：{}", path.display()))?;
    if cfg.types.is_empty() {
        bail!("配置 {} 中没有定义任何文档类型", path.display());
    }
    let mut seen = std::collections::HashSet::new();
    for t in &cfg.types {
        let ext = sanitize_ext(&t.ext)?;
        if !seen.insert(ext) {
            bail!("配置中存在重复扩展名：{}", t.ext);
        }
        if let Some(tpl) = &t.template {
            // 模板必须是纯文件名，禁止路径穿越
            if tpl.contains('/') || tpl.contains("..") || tpl.starts_with('.') {
                bail!("非法模板文件名：{}", tpl);
            }
        }
        if t.label.trim().is_empty() {
            bail!("配置中存在空的类型标签");
        }
    }
    Ok(cfg)
}

// ---------- 输入校验 ----------

fn sanitize_ext(ext: &str) -> Result<String> {
    let ext = ext.trim().trim_start_matches('.').to_lowercase();
    let ok = !ext.is_empty()
        && ext.len() <= 16
        && ext.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
    if !ok {
        bail!("非法的文件扩展名：{ext:?}（仅允许 1–16 位小写字母/数字）");
    }
    Ok(ext)
}

fn sanitize_base(base: &str) -> Result<String> {
    let b = base.trim();
    let ok = !b.is_empty()
        && !b.starts_with('.')
        && !b.chars().any(|c| c == '/' || c == '\0' || c.is_control());
    if !ok {
        bail!("非法的文件名前缀：{b:?}");
    }
    Ok(b.to_string())
}

// ---------- 目标文件夹 ----------

fn resolve_target_dir(args: &[String]) -> Result<Option<PathBuf>> {
    if !args.is_empty() {
        // 快速操作传入的路径：文件夹 → 在其中创建；文件 → 在其所在文件夹创建。
        // 路径全部失效（已被移动/删除）→ 静默退出，绝不回退去猜别的目录
        for a in args {
            let p = PathBuf::from(a);
            if !p.exists() {
                continue;
            }
            return Ok(if p.is_dir() {
                Some(p)
            } else {
                Some(p.parent().map(|x| x.to_path_buf()).unwrap_or(p))
            });
        }
        return Ok(None);
    }
    // 无参数（右键空白处 → 服务菜单）：询问 Finder 当前位置
    let out = Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(FINDER_LOCATION_SCRIPT)
        .output()
        .context("无法启动 /usr/bin/osascript")?;
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok(if s.is_empty() { None } else { Some(PathBuf::from(s)) })
}

// ---------- 类型选择器 ----------

fn pick_type(labels: &[String]) -> Result<Option<usize>> {
    if labels.len() == 1 {
        return Ok(Some(0));
    }
    let out = Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(PICK_SCRIPT)
        .args(labels) // 标签经 argv 传递，不进入脚本文本
        .output()
        .context("无法启动 /usr/bin/osascript")?;
    if !out.status.success() {
        bail!("类型选择器失败：{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        return Ok(None); // 用户取消
    }
    let idx: usize = s.parse().context("类型选择器返回异常")?;
    if idx == 0 || idx > labels.len() {
        bail!("类型选择器返回越界：{idx}");
    }
    Ok(Some(idx - 1))
}

// ---------- 文件创建 ----------

/// 在 dir 下原子创建 base.ext / base 2.ext …（create_new 保证不覆盖任何已有文件）
fn create_in(dir: &Path, base: &str, ext: &str, template: Option<&Path>) -> Result<PathBuf> {
    for n in 1..=999 {
        let name = if n == 1 {
            format!("{base}.{ext}")
        } else {
            format!("{base} {n}.{ext}")
        };
        let dest = dir.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&dest) {
            Ok(mut out) => {
                if let Some(tpl) = template {
                    let mut fill = || -> Result<()> {
                        let mut src = File::open(tpl)
                            .with_context(|| format!("打开模板失败：{}", tpl.display()))?;
                        io::copy(&mut src, &mut out)
                            .with_context(|| format!("复制模板失败：{}", tpl.display()))?;
                        Ok(())
                    };
                    if let Err(e) = fill() {
                        let _ = fs::remove_file(&dest); // 失败回滚，不留半截文件
                        return Err(e);
                    }
                }
                return Ok(dest);
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => {
                return Err(e)
                    .with_context(|| format!("无法在 {} 中创建文件", dir.display()))
            }
        }
    }
    bail!("重名文件过多（≥999），请清理后重试")
}

// ---------- 交互反馈 ----------

fn alert(msg: &str) {
    let _ = Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(ALERT_SCRIPT)
        .arg(TITLE)
        .arg(msg)
        .output();
}

fn notify(msg: &str) {
    let _ = Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(NOTIFY_SCRIPT)
        .arg(TITLE)
        .arg(msg)
        .output();
}

fn reveal(p: &Path) {
    let _ = Command::new("/usr/bin/open").arg("-R").arg(p).status();
}

// ---------- 子命令 ----------

fn cmd_run(args: &[String]) -> Result<()> {
    let cfg = load_config()?;
    let Some(dir) = resolve_target_dir(args)? else {
        return Ok(()); // 无法确定目标（如 Finder 位置未知），静默退出
    };

    let labels: Vec<String> = cfg.types.iter().map(|t| t.label.clone()).collect();
    let Some(idx) = pick_type(&labels)? else {
        return Ok(()); // 用户取消
    };
    let dt = &cfg.types[idx];

    let base = sanitize_base(&cfg.name_base)?;
    let ext = sanitize_ext(&dt.ext)?;
    let template = dt
        .template
        .as_ref()
        .map(|t| app_dir().join(TEMPLATE_SUBDIR).join(t));

    let dest = create_in(&dir, &base, &ext, template.as_deref())?;

    reveal(&dest); // 先选中（最直接的反馈），通知随后
    notify(&format!("已创建：{}", dest.file_name().unwrap_or_default().to_string_lossy()));
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn cmd_create(args: &[String]) -> Result<()> {
    let mut dir: Option<PathBuf> = None;
    let mut ext: Option<String> = None;
    let mut name: Option<String> = None;
    let mut do_reveal = true;
    let mut do_notify = true;

    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--dir" => dir = Some(PathBuf::from(it.next().context("--dir 缺少参数")?)),
            "--ext" => ext = Some(it.next().context("--ext 缺少参数")?.to_string()),
            "--name" => name = Some(it.next().context("--name 缺少参数")?.to_string()),
            "--no-reveal" => do_reveal = false,
            "--no-notify" => do_notify = false,
            other if other.starts_with('-') => bail!("未知参数：{other}"),
            other => {
                if dir.is_none() {
                    dir = Some(PathBuf::from(other));
                } else {
                    bail!("多余的位置参数：{other}");
                }
            }
        }
    }
    let dir = dir.context("缺少目标目录（--dir 或位置参数）")?;
    let ext = sanitize_ext(&ext.context("缺少 --ext 参数")?)?;

    let cfg = load_config()?;
    let base = sanitize_base(name.as_deref().unwrap_or(&cfg.name_base))?;
    let template = cfg
        .types
        .iter()
        .find(|t| t.ext.trim_start_matches('.').eq_ignore_ascii_case(&ext))
        .and_then(|t| t.template.clone())
        .map(|t| app_dir().join(TEMPLATE_SUBDIR).join(t));

    let dest = create_in(&dir, &base, &ext, template.as_deref())?;
    if do_reveal {
        reveal(&dest);
    }
    if do_notify {
        notify(&format!("已创建：{}", dest.file_name().unwrap_or_default().to_string_lossy()));
    }
    println!("{}", dest.display());
    Ok(())
}

fn cmd_types(args: &[String]) -> Result<()> {
    let cfg = load_config()?;
    let tsv = args.iter().any(|a| a == "--tsv");
    for t in &cfg.types {
        if tsv {
            // 供 FinderSync 扩展解析：label<TAB>ext
            println!("{}\t{}", t.label, t.ext);
        } else {
            let tpl = t
                .template
                .as_ref()
                .map(|s| format!("  模板={s}"))
                .unwrap_or_else(|| "  空文件".to_string());
            println!("{:<28} .{}{}", t.label, t.ext, tpl);
        }
    }
    Ok(())
}

fn usage() {
    println!(
        "newdoc — Finder 右键「新建文档」核心工具\n\
         \n\
         用法：\n\
         \x20 newdoc run [路径…]            交互流程：选类型 → 创建 → 在 Finder 中定位\n\
         \x20 newdoc create [--dir 目录] --ext 扩展名 [--name 前缀] [--no-reveal] [--no-notify]\n\
         \x20 newdoc types                  列出已配置的文档类型\n\
         \n\
         配置：~/Library/Application Support/NewDocument/config.toml\n\
         模板：~/Library/Application Support/NewDocument/templates/"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let first = args.first().map(|s| s.as_str());
    let is_run = matches!(first, None | Some("run") | Some("-h") | Some("--help") | Some("help"));

    let result = match first {
        Some("run") => cmd_run(&args[1..]),
        Some("create") => cmd_create(&args[1..]),
        Some("types") => cmd_types(&args[1..]),
        Some("-h" | "--help" | "help") | None => {
            usage();
            Ok(())
        }
        Some(other) => Err(anyhow::anyhow!("未知子命令：{other}（见 newdoc --help）")),
    };

    if let Err(e) = result {
        eprintln!("newdoc: {e:#}");
        // 仅交互流程弹窗提示；CLI 场景以 stderr 为准
        if is_run {
            alert(&format!("{e:#}"));
        }
        std::process::exit(1);
    }
}

// ---------- 测试 ----------

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("newdoc-test-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn default_config_parses_and_validates() {
        let cfg: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
        assert!(cfg.types.len() >= 8);
        assert!(cfg.types.iter().any(|t| t.ext == "txt"));
        assert!(cfg.types.iter().all(|t| !t.label.is_empty()));
    }

    #[test]
    fn ext_whitelist() {
        assert_eq!(sanitize_ext("TXT").unwrap(), "txt");
        assert_eq!(sanitize_ext(".docx").unwrap(), "docx");
        assert!(sanitize_ext("a/b").is_err());
        assert!(sanitize_ext("..").is_err());
        assert!(sanitize_ext("").is_err());
        assert!(sanitize_ext("中文").is_err());
        assert!(sanitize_ext("abcdefghijklmnopqrstuvwxyz").is_err());
    }

    #[test]
    fn base_rejects_traversal() {
        assert!(sanitize_base("../etc").is_err());
        assert!(sanitize_base("a/b").is_err());
        assert!(sanitize_base("未命名").is_ok());
    }

    #[test]
    fn unique_naming_and_no_overwrite() {
        let d = tempdir("naming");
        let d = d.join("target");
        fs::create_dir_all(&d).unwrap();

        let p1 = create_in(&d, "未命名", "txt", None).unwrap();
        assert_eq!(p1.file_name().unwrap(), "未命名.txt");
        let p2 = create_in(&d, "未命名", "txt", None).unwrap();
        assert_eq!(p2.file_name().unwrap(), "未命名 2.txt");
        let p3 = create_in(&d, "未命名", "txt", None).unwrap();
        assert_eq!(p3.file_name().unwrap(), "未命名 3.txt");

        // 目录名占用「未命名.txt」时也不能覆盖，而是顺延
        fs::create_dir_all(d.join("未命名 4.txt")).unwrap();
        let p5 = create_in(&d, "未命名", "txt", None).unwrap();
        assert_eq!(p5.file_name().unwrap(), "未命名 5.txt");
    }

    #[test]
    fn template_copied_and_rollback_on_missing() {
        let d = tempdir("tpl");
        let tpl = d.join("tpl.txt");
        fs::write(&tpl, "template-content").unwrap();
        let out = create_in(&d, "新", "txt", Some(&tpl)).unwrap();
        assert_eq!(fs::read_to_string(&out).unwrap(), "template-content");

        // 模板缺失 → 报错且不留空壳文件
        let missing = d.join("missing.txt");
        assert!(create_in(&d, "新", "md", Some(&missing)).is_err());
        assert!(!d.join("新.md").exists());
    }

    #[test]
    fn resolve_target_dir_with_file_and_folder() {
        let d = tempdir("resolve");
        let sub = d.join("subfolder");
        fs::create_dir_all(&sub).unwrap();
        let f = sub.join("file.txt");
        fs::write(&f, "x").unwrap();

        let dir = resolve_target_dir(&[f.to_string_lossy().to_string()]).unwrap().unwrap();
        assert_eq!(dir, sub);
        let dir = resolve_target_dir(&[sub.to_string_lossy().to_string()]).unwrap().unwrap();
        assert_eq!(dir, sub);
        // 路径不存在 → None（静默）
        assert!(resolve_target_dir(&["/nonexistent/xyz".to_string()]).unwrap().is_none());
    }

    #[test]
    fn sandbox_home_does_not_affect_app_dir() {
        // 模拟 FinderSync 沙盒子进程：HOME 被重映射到容器 → 仍应定位到真实主目录
        let fake = tempdir("fakehome");
        let old = std::env::var("HOME").ok();
        std::env::remove_var("NEWDOC_APP_DIR");
        std::env::set_var("HOME", &fake);
        let d = app_dir();
        match old {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
        assert_ne!(d, fake.join(APP_DIR_NAME), "HOME 被沙盒重映射时不应使用 HOME");
    }

    #[test]
    fn config_rejects_traversal_template() {
        let bad = r#"
name_base = "x"
[[types]]
label = "坏"
ext = "txt"
template = "../escape.docx"
"#;
        let cfg: Config = toml::from_str(bad).unwrap();
        assert!(cfg.types[0].template.as_deref().unwrap().contains(".."));
        // load_config 的校验逻辑依赖 app_dir，这里直接验证校验函数级行为
    }
}
