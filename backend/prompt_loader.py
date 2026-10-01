import re
from pathlib import Path


class PromptLoader:
    def __init__(self, root: Path | str) -> None:
        self.root = Path(root)

    def load(self, prompt_path: str) -> str:
        path = self._resolve(prompt_path)
        if not path.exists():
            raise FileNotFoundError(f"Prompt file not found: {path}")
        return path.read_text(encoding="utf-8")

    def render(self, prompt_path: str, **variables: object) -> str:
        template = self.load(prompt_path)
        names = set(re.findall(r"{{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*}}", template))
        missing = sorted(name for name in names if name not in variables)
        if missing:
            raise KeyError(
                f"Missing prompt variable(s) for {prompt_path}: {', '.join(missing)}"
            )

        rendered = template
        for name in names:
            rendered = re.sub(
                r"{{\s*" + re.escape(name) + r"\s*}}",
                str(variables[name]),
                rendered,
            )
        return rendered.strip()

    def _resolve(self, prompt_path: str) -> Path:
        normalized = prompt_path.replace("\\", "/").lstrip("/")
        path = (self.root / normalized).resolve()
        root = self.root.resolve()
        if root != path and root not in path.parents:
            raise ValueError(f"Prompt path escapes prompt root: {prompt_path}")
        return path
