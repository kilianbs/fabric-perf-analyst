"""PreToolUse hook: keeps Livy statements read-only.

FabricPerfAnalyst runs diagnostic Livy statements (DESCRIBE DETAIL, EXPLAIN, bounded SELECT)
without asking for confirmation. This hook is the deterministic limit behind that autonomy. It is
declared only in the agent's frontmatter (.claude/agents/FabricPerfAnalyst.md), so it runs only while
that agent runs and never constrains the main session or other agents. It is an allowlist, not a
keyword denylist:

- A command that submits to a Livy statements endpoint must be `az rest ... --body @<file>` with a
  literal path. Inline bodies, other HTTP clients and other body flags are blocked, because the code
  they send cannot be inspected reliably.
- The body must be JSON with `"kind": "pyspark"`. Its code may only contain expression statements
  built from `spark.sql("<read-only SQL>")` followed by read methods, `spark.conf.get(...)`,
  `spark.sparkContext.applicationId`, `spark.version` and `print(...)`.
- Each SQL statement must start with DESCRIBE, DESC, SHOW, EXPLAIN, SELECT or WITH, or be a
  `SET <key>` without a value.

Exit code 2 blocks the tool call and returns stderr to the model.
"""

import ast
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SHELL_TOOLS = frozenset({"Bash", "PowerShell"})
BLOCK = 2

# Livy statement endpoint: .../livyapi/versions/<v>/sessions/<id>/statements[/<n>[/cancel]].
STATEMENTS_URL = re.compile(r"/sessions/[^/\s\"']+/statements\b", re.IGNORECASE)
CANCEL_URL = re.compile(r"/sessions/[^/\s\"']+/statements/[^/\s\"']+/cancel\b", re.IGNORECASE)
POST_METHOD = re.compile(r"(?:--method|-X|-Method)[\s=]*[\"']?(?:post|put|patch)\b", re.IGNORECASE)
BODY_FLAG = re.compile(
    r"(?<![\w-])(?:--body|--data[\w-]*|-d|--json|--form|-F|--upload-file|-T|-Body|-InFile)(?![\w-])",
    re.IGNORECASE,
)
AZ_REST_BODY_FILE = re.compile(r"--body[\s=]+[\"']?@([^\s\"']+)[\"']?", re.IGNORECASE)
SUBSTITUTION = re.compile(r"\$\(|`|<\(")

READ_METHODS = frozenset(
    {"show", "collect", "count", "first", "head", "take", "limit", "toJSON",
     "filter", "where", "select", "selectExpr", "orderBy", "sort", "groupBy", "agg", "distinct"}
)
SQL_READ_START = re.compile(r"^(DESCRIBE|DESC|SHOW|EXPLAIN|SELECT|WITH)\b", re.IGNORECASE)
SQL_SET_READ = re.compile(r"^SET(\s+-v|\s+[\w.\-]+)?$", re.IGNORECASE)
SQL_WRITE_IN_QUERY = re.compile(
    r"\b(INSERT|MERGE|UPDATE|DELETE|OVERWRITE|CACHE|UNCACHE|REFLECT|JAVA_METHOD)\b", re.IGNORECASE
)
JVM_CALL = re.compile(r"\b(REFLECT|JAVA_METHOD)\b", re.IGNORECASE)
SQL_STRING_LITERAL = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"")
SQL_COMMENT = re.compile(r"--[^\n]*|/\*.*?\*/", re.DOTALL)


class Rejected(Exception):
    """The command or statement is outside the allowlist."""


def block(reason: str) -> int:
    print(
        f"Blocked by livy_readonly_guard: {reason}. Livy statements are allowlisted read-only "
        "diagnostics (agent FabricPerfAnalyst, Action tiers, Livy guard): submit them with "
        "`az rest --method post --body @<file>` and a pyspark body that only calls spark.sql() "
        "with DESCRIBE, SHOW, EXPLAIN, SELECT or WITH and read methods. Never rephrase a write to "
        "get past this check; if a read is blocked, simplify it or record it under "
        "Notas > Datos no obtenidos.",
        file=sys.stderr,
    )
    return BLOCK


# SQL allowlist.


def check_sql(sql: str) -> None:
    statements = [s.strip() for s in SQL_COMMENT.sub(" ", sql).split(";") if s.strip()]
    if not statements:
        raise Rejected("empty SQL statement")
    for statement in statements:
        if SQL_SET_READ.match(statement):
            continue
        if not SQL_READ_START.match(statement):
            raise Rejected(f"SQL statement `{statement[:60]}` is not a read")
        write = SQL_WRITE_IN_QUERY.search(SQL_STRING_LITERAL.sub("''", statement))
        if write and statement.split()[0].upper() in {"SELECT", "WITH"}:
            raise Rejected(f"SQL statement contains `{write.group(0)}`")


# PySpark allowlist.


def is_spark(node: ast.expr) -> bool:
    return isinstance(node, ast.Name) and node.id == "spark"


def check_constant(node: ast.expr) -> None:
    """Arguments of read methods may only be literals; strings may not call JVM methods."""
    if isinstance(node, ast.Constant):
        jvm_call = JVM_CALL.search(node.value) if isinstance(node.value, str) else None
        if jvm_call:
            raise Rejected(f"argument calls `{jvm_call.group(0)}`")
        return
    if isinstance(node, (ast.List, ast.Tuple)):
        for item in node.elts:
            check_constant(item)
        return
    if isinstance(node, ast.Dict):
        for item in [*node.keys, *node.values]:
            if item is None:
                raise Rejected("dictionary unpacking is not allowed")
            check_constant(item)
        return
    raise Rejected(f"argument `{ast.unparse(node)}` is not a literal")


def check_call_args(call: ast.Call) -> None:
    for arg in call.args:
        check_constant(arg)
    for keyword in call.keywords:
        if keyword.arg is None:
            raise Rejected("keyword unpacking is not allowed")
        check_constant(keyword.value)


def check_spark_expr(node: ast.expr) -> None:
    # spark.sparkContext.applicationId, spark.version
    if isinstance(node, ast.Attribute):
        if node.attr == "applicationId" and isinstance(node.value, ast.Attribute):
            if node.value.attr == "sparkContext" and is_spark(node.value.value):
                return
        if node.attr == "version" and is_spark(node.value):
            return
        raise Rejected(f"`{ast.unparse(node)}` is not an allowed read")
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
        raise Rejected(f"`{ast.unparse(node)}` is not an allowed read")
    func = node.func
    # spark.sql("<sql>")
    if func.attr == "sql" and is_spark(func.value):
        if len(node.args) != 1 or node.keywords or not isinstance(node.args[0], ast.Constant) \
                or not isinstance(node.args[0].value, str):
            raise Rejected("spark.sql() takes exactly one literal SQL string")
        check_sql(node.args[0].value)
        return
    # spark.conf.get("<key>"[, "<default>"])
    if func.attr == "get" and isinstance(func.value, ast.Attribute) and func.value.attr == "conf" \
            and is_spark(func.value.value):
        check_call_args(node)
        return
    # <allowed expr>.<read method>(<literals>)
    if func.attr in READ_METHODS:
        check_call_args(node)
        check_spark_expr(func.value)
        return
    raise Rejected(f"`{func.attr}` is not an allowed read method")


def check_pyspark(code: str) -> None:
    try:
        tree = ast.parse(code)
    except SyntaxError as error:
        raise Rejected(f"code is not plain Python ({error.msg})") from None
    if not tree.body:
        raise Rejected("empty code")
    for statement in tree.body:
        if not isinstance(statement, ast.Expr):
            raise Rejected(f"`{ast.unparse(statement)[:60]}` is not an expression")
        value = statement.value
        if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "print":
            if value.keywords:
                raise Rejected("print() takes no keywords here")
            for arg in value.args:
                check_spark_expr(arg)
            continue
        check_spark_expr(value)


# Command shape.


def resolve_body_path(raw: str, cwd: str | None) -> Path:
    if "$" in raw or "%" in raw:
        raise Rejected(f"body path `{raw}` uses a variable; write the path literally")
    path = Path(os.path.expanduser(raw))
    if not path.is_absolute() and cwd:
        path = Path(cwd) / path
    if path.is_file():
        return path
    cygpath = shutil.which("cygpath")
    if raw.startswith("/") and cygpath:
        converted = subprocess.run([cygpath, "-w", raw], capture_output=True, text=True, check=False)
        candidate = Path(converted.stdout.strip())
        if converted.returncode == 0 and candidate.is_file():
            return candidate
    raise Rejected(f"body file `{raw}` cannot be read")


def check_body_file(path: Path) -> None:
    try:
        body = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise Rejected(f"body file `{path}` is not readable JSON") from None
    if not isinstance(body, dict) or not isinstance(body.get("code"), str):
        raise Rejected("body must be a JSON object with a `code` string")
    if body.get("kind") != "pyspark":
        raise Rejected("body must set `\"kind\": \"pyspark\"`")
    check_pyspark(body["code"])


def check(command: str, cwd: str | None) -> None:
    if not STATEMENTS_URL.search(command):
        return
    has_body = bool(BODY_FLAG.search(command))
    if not has_body and not POST_METHOD.search(command):
        return  # GET (poll or list) or DELETE: no code is sent
    if not has_body:
        if CANCEL_URL.search(command):
            return
        raise Rejected("POST to the statements endpoint without a body file")
    if SUBSTITUTION.search(command):
        raise Rejected("command substitution in a statement submission")
    body_files = AZ_REST_BODY_FILE.findall(command)
    if not re.search(r"\baz\s+rest\b", command) or len(body_files) != 1 \
            or len(BODY_FLAG.findall(command)) != 1:
        raise Rejected("statements must be submitted with `az rest` and exactly one `--body @<file>`")
    check_body_file(resolve_body_path(body_files[0], cwd))


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        # Fail closed only where this guard applies.
        return block("hook input is not valid JSON") if "statements" in raw.lower() else 0
    if payload.get("tool_name") not in SHELL_TOOLS:
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    try:
        check(command, payload.get("cwd"))
    except Rejected as error:
        return block(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
