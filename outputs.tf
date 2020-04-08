output "root_url" {
  value = aws_api_gateway_deployment.hola_lambda_deployment.invoke_url
}
