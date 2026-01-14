// @ts-check
import { includeIgnoreFile } from "@eslint/compat";
import { defaultConfig } from "@flarenetwork/eslint-config-flare";
import prettier from "eslint-config-prettier";
import path from "node:path";
import { fileURLToPath } from "node:url";

const gitignorePath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".gitignore");

export default [
    includeIgnoreFile(gitignorePath),
    ...defaultConfig,
    prettier,
    {
        rules: {
            "@typescript-eslint/no-unsafe-assignment": "off",
            "@typescript-eslint/no-unsafe-argument": "off",
            "@typescript-eslint/no-unsafe-call": "off",
            "@typescript-eslint/no-unsafe-member-access": "off",
            "@typescript-eslint/no-unsafe-return": "off",
            "@typescript-eslint/no-explicit-any": "off",
        },
    },
];
