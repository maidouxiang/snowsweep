#!/usr/bin/env python3
"""发布前剔除安装包里夹带的本机绝对路径。

Swift 会把 `#filePath` 常量原样编进二进制（"Fatal error"、断言消息里），
公开分发前必须换成中性占位路径，否则等于公开了打包机的用户名与目录结构。

用法：
    python3 strip-local-paths.py "/Applications/雪.app"

规则：把等长的 /Users/<本机用户名> 替换成 /private/example（字节长度必须一致，
否则会破坏 Mach-O 结构）。改完必须重新签名（ad-hoc 即可）：
    codesign --force --deep --sign - "/Applications/雪.app"

注意：必须在 App 组装完成之后再跑。install 脚本每次都会从 .build/release
重新拷贝可执行文件，先跑补丁会被覆盖。
"""
import os
import sys
import getpass

OLD = f"/Users/{getpass.getuser()}".encode()
NEW = b"/private/example"

def main() -> int:
    if len(OLD) != len(NEW):
        print(f"占位串长度不匹配：{OLD!r} vs {NEW!r}", file=sys.stderr)
        return 2
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    total = 0
    for root, _, files in os.walk(target):
        for name in files:
            path = os.path.join(root, name)
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            if OLD in data:
                count = data.count(OLD)
                total += count
                open(path, "wb").write(data.replace(OLD, NEW))
                print(f"{path}: {count}")
    print(f"合计替换 {total} 处")
    return 0 if total else 1

if __name__ == "__main__":
    sys.exit(main())
