#!/usr/bin/env python3
"""Regression tests for the Swift source scan used by the UI wiring gate."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "ui_wiring", Path(__file__).with_name("check-ui-wiring.py")
)
wiring = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiring)


class SwiftUsageTests(unittest.TestCase):
    def test_localized_pending_input_is_not_a_use(self):
        source = r'RimeLocalization.text("Waiting for dictionaries. Pending input: \(engine.pendingUse)")'
        self.assertNotIn("input", wiring.used_names(source))
        self.assertIn("pendingUse", wiring.used_names(source))

    def test_member_calls_and_argument_labels_are_uses(self):
        names = wiring.used_names("engine.isRunning; engine.isSessionOpen; run(input: value)")
        self.assertTrue({"isRunning", "isSessionOpen", "run", "input"} <= names)

    def test_comments_and_nested_block_comments_are_ignored(self):
        source = """
        // object.lineUse; callUse(); argumentUse:
        /* object.blockUse /* nestedUse() */ afterNestedUse() */
        engine.realUse()
        """
        self.assertEqual(wiring.used_names(source), {"realUse"})

    def test_escaped_quotes_and_literal_interpolation_are_ignored(self):
        source = r'"escaped \" input: .fake() \\(engine.literalUse)"; engine.realUse'
        self.assertEqual(wiring.used_names(source), {"realUse"})

    def test_nested_interpolation_preserves_expressions(self):
        source = r'"input: \(render("nested: \(engine.nestedUse)", value: engine.outerUse))"'
        self.assertEqual(wiring.used_names(source), {"render", "value", "nestedUse", "outerUse"})

    def test_multiline_and_raw_strings_preserve_only_active_interpolation(self):
        source = '''
        """ .fake() input: \\(engine.multilineUse) """
        ##"raw: .fake() \\(engine.inactiveUse) \\##(engine.rawUse)"##
        #""" multiline: .fake() \\#(engine.rawMultilineUse) """#
        '''
        self.assertEqual(
            wiring.used_names(source), {"multilineUse", "rawUse", "rawMultilineUse"}
        )

    def test_comments_and_nested_parentheses_inside_interpolation(self):
        source = r'"\(wrap(/* ) */ (engine.realUse))) input:"'
        self.assertEqual(wiring.used_names(source), {"wrap", "realUse"})

    def test_text_does_not_join_unrelated_tokens(self):
        self.assertNotIn("input", wiring.used_names('input "label" : value'))


if __name__ == "__main__":
    unittest.main()
