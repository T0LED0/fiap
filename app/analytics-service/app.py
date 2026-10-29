import os
import sys
import threading
import json
import uuid
import time
import logging
import boto3
from botocore.exceptions import NoCredentialsError, ClientError
from flask import Flask, jsonify
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

load_dotenv()

AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.critical("Erro: AWS_REGION, AWS_SQS_URL, e AWS_DYNAMODB_TABLE devem ser definidos.")
    sys.exit(1)

try:
    session = boto3.Session(region_name=AWS_REGION)
    dynamo_endpoint = os.getenv("DYNAMODB_ENDPOINT_URL") or os.getenv("AWS_ENDPOINT_URL")
    sqs_endpoint = os.getenv("SQS_ENDPOINT_URL") or os.getenv("AWS_ENDPOINT_URL")
    
    sqs_client = session.client("sqs", endpoint_url=sqs_endpoint)
    dynamodb_client = session.client("dynamodb", endpoint_url=dynamo_endpoint)
    log.info(f"Clientes Boto3 inicializados na região {AWS_REGION} (DynamoDB: {dynamo_endpoint or 'AWS'}, SQS: {sqs_endpoint or 'AWS'})")
except NoCredentialsError:
    log.critical("Credenciais da AWS não encontradas. Verifique seu ambiente.")
    sys.exit(1)
except Exception as e:
    log.critical(f"Erro ao inicializar o Boto3: {e}")
    sys.exit(1)


def ensure_dynamodb_table():
    """Garante que a tabela exista (útil com DynamoDB Local)"""
    try:
        dynamodb_client.describe_table(TableName=DYNAMODB_TABLE_NAME)
        log.info(f"Tabela DynamoDB '{DYNAMODB_TABLE_NAME}' pronta e disponível.")
    except Exception as e:
        log.info(f"Tabela '{DYNAMODB_TABLE_NAME}' não encontrada ou erro de leitura: {e}. Tentando inicializar...")
        try:
            dynamodb_client.create_table(
                TableName=DYNAMODB_TABLE_NAME,
                AttributeDefinitions=[
                    {'AttributeName': 'event_id', 'AttributeType': 'S'}
                ],
                KeySchema=[
                    {'AttributeName': 'event_id', 'KeyType': 'HASH'}
                ],
                BillingMode='PAY_PER_REQUEST'
            )
            log.info(f"Tabela DynamoDB '{DYNAMODB_TABLE_NAME}' criada com sucesso.")
        except Exception as create_err:
            log.warning(f"Aviso: Não foi possível criar tabela automaticamente: {create_err}")


def ensure_sqs_queue():
    """Garante que a fila SQS exista (útil com Floci / ambientes locais)"""
    try:
        queue_name = SQS_QUEUE_URL.rstrip("/").split("/")[-1]
        sqs_client.create_queue(QueueName=queue_name)
        log.info(f"Fila SQS '{queue_name}' verificada/pronta.")
    except Exception as e:
        log.warning(f"Aviso ao verificar/criar fila SQS: {e}")


def process_message(message):
    """Processa uma única mensagem SQS e persiste no DynamoDB"""
    try:
        log.info(f"Processando mensagem ID: {message['MessageId']}")
        body = json.loads(message['Body'])
        
        event_id = str(uuid.uuid4())
        item = {
            'event_id': {'S': event_id},
            'user_id': {'S': body['user_id']},
            'flag_name': {'S': body['flag_name']},
            'result': {'BOOL': body['result']},
            'timestamp': {'S': body['timestamp']}
        }
        
        dynamodb_client.put_item(
            TableName=DYNAMODB_TABLE_NAME,
            Item=item
        )
        log.info(f"Evento {event_id} (Flag: {body['flag_name']}) salvo no DynamoDB.")
        
        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=message['ReceiptHandle']
        )
    except json.JSONDecodeError:
        log.error(f"Erro ao decodificar JSON da mensagem ID: {message['MessageId']}")
    except ClientError as e:
        log.error(f"Erro do Boto3 (DynamoDB ou SQS) ao processar {message['MessageId']}: {e}")
    except Exception as e:
        log.error(f"Erro inesperado ao processar {message['MessageId']}: {e}")

def sqs_worker_loop():
    """Loop principal do worker que consome a fila SQS"""
    log.info("Iniciando o worker SQS...")
    while True:
        try:
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20
            )
            
            messages = response.get('Messages', [])
            if not messages:
                continue
                
            log.info(f"Recebidas {len(messages)} mensagens.")
            for message in messages:
                process_message(message)
                
        except ClientError as e:
            log.error(f"Erro do Boto3 no loop principal do SQS: {e}")
            time.sleep(10)
        except Exception as e:
            log.error(f"Erro inesperado no loop principal do SQS: {e}")
            time.sleep(10)

app = Flask(__name__)

@app.route('/health')
def health():
    return jsonify({"status": "ok"})

def start_worker():
    """Garante tabela e fila e inicia o worker SQS em background"""
    ensure_dynamodb_table()
    ensure_sqs_queue()
    worker_thread = threading.Thread(target=sqs_worker_loop, daemon=True)
    worker_thread.start()

start_worker()

if __name__ == '__main__':
    port = int(os.getenv("PORT", 8005))
    app.run(host='0.0.0.0', port=port, debug=False)