#
# VARIABLES
#
variable "aws_region" {
  description = "The AWS region."
  default     = "us-east-1"
}

variable "aws_access_key" {
  description = ""
}

variable "aws_secret_key" {
  description = ""
}

#
# PROVIDERS
#
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.aws_region
}

provider "archive" {}

#
# LOCALS
#
locals {
  bucket_name = "hola-bucket-${random_pet.this.id}"
  common_tags = {}
}

resource "random_pet" "this" {
  length = 2
}

#
# S3
#
resource "aws_s3_bucket" "log_bucket" {
  bucket = format("log-%s",local.bucket_name)
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket" "webpage_bucket" {
  bucket = local.bucket_name
  region = var.aws_region
  acl = "public-read"
  website {
    index_document = "index.html"
    error_document = "error.html"
  }
  versioning {
    enabled = true
  }
  # DISABLED FOR TEST PURPOSES - TURN ON IF STILL COMMENTED OUT - RB
  #logging {
  #  target_bucket = aws_s3_bucket.log_bucket.id
  #  target_prefix = "log/"
  #}
  depends_on = [
    aws_s3_bucket.log_bucket
  ]
}

#
# LAMBDA
#
data "archive_file" "zip" {
  type        = "zip"
  source_file = "hola_lambda.py"
  output_path = "hola_lambda.zip"
}

resource "aws_iam_role" "iam_for_hola_lambda" {
  name = "iam_for_hola_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_lambda_function" "hola_lambda" {
  filename      = "hola_lambda.zip"
  function_name = "hola_lambda"
  role          = aws_iam_role.iam_for_hola_lambda.arn
  handler       = "hola_lambda.lambda_handler"
  source_code_hash = filebase64sha256("hola_lambda.zip")
  runtime       = "python3.6"
  timeout       = 60
  #environment { variables = {} }
  depends_on = [
    aws_api_gateway_rest_api.hola_lambda_api_gateway
  ]
}

#
# API GATEWAY
#
resource "aws_api_gateway_rest_api" "hola_lambda_api_gateway" {
  name = "hola_lambda_rest_api_gateway"
  description = "Hola! I am Serverless!"
}

resource "aws_api_gateway_resource" "hola_lambda_resource" {
  rest_api_id = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
  parent_id   = aws_api_gateway_rest_api.hola_lambda_api_gateway.root_resource_id
  path_part   = "hola_lambda_method"
}

resource "aws_api_gateway_method" "hola_lambda_method" {
  rest_api_id   = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
  resource_id   = aws_api_gateway_resource.hola_lambda_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "hola_lambda_integration" {
  rest_api_id                 = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
  resource_id                 = aws_api_gateway_method.hola_lambda_method.resource_id
  http_method                 = aws_api_gateway_method.hola_lambda_method.http_method
  integration_http_method     = aws_api_gateway_method.hola_lambda_method.http_method
  type                        = "AWS_PROXY"
  uri                         = aws_lambda_function.hola_lambda.invoke_arn
  depends_on = [
    aws_lambda_function.hola_lambda
  ]
}

#
# EMPTY TEST ENDPOINT
#
resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
  resource_id   = aws_api_gateway_rest_api.hola_lambda_api_gateway.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method
  integration_http_method = "GET"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.hola_lambda.invoke_arn
  depends_on = [
    aws_lambda_function.hola_lambda
  ]
}

resource "aws_api_gateway_deployment" "hola_lambda_deployment" {
  depends_on = [ aws_api_gateway_integration.hola_lambda_integration ] #, 
                 #aws_api_gateway_integration.lambda_root ]
  rest_api_id = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
  stage_name  = "hola_lambda_stage"
}

#
# SIMPLE WEBPAGE FILES
#
resource "local_file" "index_file_template" {
  count = 1
  content = templatefile(format("%s/index_template.html", path.module), { 
      bucket_name = aws_s3_bucket.webpage_bucket.id, 
      api_gateway_link = aws_api_gateway_deployment.hola_lambda_deployment.invoke_url
    })
  filename = format("%s/index.html", path.module)
  depends_on = [
    aws_api_gateway_deployment.hola_lambda_deployment
  ]
}

resource "aws_s3_bucket_object" "index_file" {
  bucket = local.bucket_name
  source = "index.html"
  key    = "index.html"
  #etag   = filemd5("index.html") # TODO - RB
  content_type = "text/html"
  acl    = "public-read"
  depends_on = [
    local_file.index_file_template,
    aws_s3_bucket.webpage_bucket
  ]
}

resource "aws_s3_bucket_object" "error_file" {
  bucket = local.bucket_name
  source = "error.html"
  key    = "error.html"
  etag   = filemd5("error.html")
  content_type = "text/html"
  acl    = "public-read"
  depends_on = [
    aws_s3_bucket.webpage_bucket
  ]
}

resource "aws_s3_bucket_object" "image_file" {
  bucket = local.bucket_name
  source = "default_image.jpg"
  key = "default_image.jpg"
  etag = filemd5("default_image.jpg")
  content_type = "image/jpeg"
  acl    = "public-read"
  depends_on = [
    aws_s3_bucket.webpage_bucket
  ]
}

#
# INTERESTING WAY OF CALLING DIRECTLY AWS CLI - RB
#
#resource "null_resource" "remove_and_upload_to_s3" {
#  provisioner "local-exec" {
#    command = format("aws s3 sync %s/images s3://%s/images/", path.module, aws_s3_bucket.webpage_bucket.id)
#  }
#}

#
# EMPTY TEST ENDPOINT
#
#resource "aws_api_gateway_method" "proxy_root" {
#  rest_api_id   = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
#  resource_id   = aws_api_gateway_rest_api.hola_lambda_api_gateway.root_resource_id
#  http_method   = "ANY"
#  authorization = "NONE"
#}
#
#resource "aws_api_gateway_integration" "lambda_root" {
#  rest_api_id = aws_api_gateway_rest_api.hola_lambda_api_gateway.id
#  resource_id = aws_api_gateway_method.proxy_root.resource_id
#  http_method = aws_api_gateway_method.proxy_root.http_method
#  integration_http_method = "GET"
#  type                    = "AWS_PROXY"
#  uri                     = aws_lambda_function.hola_lambda.invoke_arn
#  depends_on = [
#    aws_lambda_function.hola_lambda
#  ]
#}