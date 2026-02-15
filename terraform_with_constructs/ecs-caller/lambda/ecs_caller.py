import json
import urllib.request
import os


def lambda_handler(event, context):
    alb_dns = os.environ['ALB_DNS']
    app_name = os.environ['APP_NAME']

    url = f"http://{alb_dns}/{app_name}/"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return {
                'statusCode': response.status,
                'body': json.loads(response.read().decode('utf-8'))
            }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': {'error': str(e)}
        }
