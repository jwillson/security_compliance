import json
import csv

input_file = 'nist_800_171r3_stig.json'
output_file = 'nist_800_171r3_stig_checklist.csv'


def convert_to_csv():
    with open(input_file, 'r') as f:
        data = json.load(f)

    findings = data.get('findings', [])
    headers = ['ID', 'Family', 'Title', 'Has OS Commands', 'Commands', 'Guidance']

    with open(output_file, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()

        for item in findings:
            writer.writerow({
                'ID': item['id'],
                'Family': item['family'],
                'Title': item['title'],
                'Has OS Commands': item['has_os_commands'],
                'Commands': " | ".join(item['commands']) if item['commands'] else "N/A",
                'Guidance': item['guidance']
            })

    print(f"Successfully exported {len(findings)} requirements to {output_file}")

if __name__ == "__main__":
    convert_to_csv()
