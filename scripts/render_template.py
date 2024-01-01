#!/usr/bin/python

import argparse
from jinja2 import Environment, FileSystemLoader

def main():
    # Create argument parser
    parser = argparse.ArgumentParser(description="Process variables for Jinja2 template")

    # Add arguments for variable-value pairs
    parser.add_argument("variables", nargs="+", help="Variable-value pairs (e.g., name=John email=john@example.com)")
    
    # Add argument for the template filename
    parser.add_argument("--template", default="template.html", help="Jinja2 template filename")

    # Specify the path to your templates directory
    template_dir = "templates"

    # Parse command-line arguments
    args = parser.parse_args()

    # Create the Jinja2 environment
    env = Environment(loader=FileSystemLoader(template_dir))

    # Load the template using the provided filename
    template = env.get_template(args.template)

    # Parse variable-value pairs and construct data dictionary
    data = {}
    for arg in args.variables:
        key, value = arg.split("=")
        data[key] = value

    # Render the template with the provided data
    output = template.render(data)

    # Output the rendered content
    print(output)

if __name__ == "__main__":
    main()

