schema_version = 1

project {
  license        = "MIT"
  copyright_year = 2025
  copyright_holder = "n8n GmbH"

  header_ignore = [
    # Generated / vendored files we do not own
    ".terraform/**",
    ".terraform.lock.hcl",
    "**/*.tfstate",
    "**/*.tfstate.*",
    "**/*.tfvars",
    "**/*.tfvars.example",

    # Markdown / docs / config files where the header would be noise
    "**/*.md",
    "LICENSE",
    ".copywrite.hcl",
    ".gitignore",
    ".terraform-docs.yml",
    ".tflint.hcl",
    ".github/**",
  ]
}
