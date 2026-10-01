import tempfile
import unittest
from pathlib import Path

from prompt_loader import PromptLoader


class PromptLoaderTest(unittest.TestCase):
    def test_render_injects_variables(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "demo.md").write_text("Hello {{ name }}", encoding="utf-8")

            loader = PromptLoader(root)

            self.assertEqual(loader.render("demo.md", name="Lumin"), "Hello Lumin")

    def test_missing_prompt_is_clear(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            loader = PromptLoader(temp_dir)

            with self.assertRaises(FileNotFoundError):
                loader.load("missing.md")

    def test_missing_variable_is_clear(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "demo.md").write_text("Hello {{ name }}", encoding="utf-8")
            loader = PromptLoader(root)

            with self.assertRaises(KeyError):
                loader.render("demo.md")


if __name__ == "__main__":
    unittest.main()
