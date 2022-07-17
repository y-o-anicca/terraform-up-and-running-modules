terraform {
  backend "s3" {
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "us-east-2"

    # Replace this with your DynamoDB table name!
    dynamodb_table = "og-terraform-up-and-running-locks"
    encrypt = true 
  }
}

resource "aws_launch_configuration" "example" {
  image_id = "ami-0c55b159cbfafe1f0"
  instance_type = var.instance_type
  security_groups = [ aws_security_group.instance.id ]

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              echo "${data.terraform_remote_state.db.outputs.address}" >> index.html
              echo "${data.terraform_remote_state.db.outputs.port}" >> index.html
              nohup busybox httpd -f -p ${var.server_port} &
              EOF

  # Required when using a launch configuration with an auto scaling group. 
  # https://www.terraform.io/docs/providers/aws/r/launch_configuration.html 
  lifecycle {
    create_before_destroy = true 
  }
}

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  // This parameter specifies to the ASG into which VPC subnets the EC2 Instances should be deployed
  vpc_zone_identifier = data.aws_subnet_ids.default.ids

  // This let the target group know which EC2 Instances to send requests to.
  target_group_arns = [aws_lb_target_group.asg.arn]
  // It instructs the ASG to use the target group’s health check to determine whether an Instance is healthy 
  // and to automatically replace Instances if the target group reports them as unhealthy. 
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key = "Name"
    value = var.cluster_name
    propagate_at_launch = true
  }
}

resource "aws_lb" "example" {
  name = var.cluster_name
  load_balancer_type = "application"
  subnets = data.aws_subnet_ids.default.ids
  security_groups = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port = local.http_port
  protocol = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    } 
  }
}

resource "aws_lb_target_group" "asg" {
  name = var.cluster_name 
  port = var.server_port
  protocol = "HTTP"
  vpc_id =data.aws_vpc.default.id

  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

// The code adds a listener rule that send requests that match any path to the target group that contains your ASG.
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

// By default, AWS does not allow any incoming or outgoing traffic from an EC2 Instance.
// To Allow the EC2 to receive traffic on 8080, It requires you to create a security group.
resource "aws_security_group" "instance" { 
  name = "${var.cluster_name}-instance"
  
  ingress {
    from_port = var.server_port
    to_port = var.server_port 
    protocol = local.tcp_protocol
    // The CIDR block 0.0.0.0/0 is an IP address range that includes all possible IP addresses.
    // so this security group allows incoming requests on port 8080 from any IP.7
    cidr_blocks = local.all_ips
  } 
}

resource "aws_security_group" "alb" { 
  name  ="${var.cluster_name}-alb"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port = local.http_port 
  to_port = local.http_port 
  protocol = local.tcp_protocol 
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" { 
  type = "egress"
  security_group_id = aws_security_group.alb.id
  from_port = local.any_port 
  to_port = local.any_port 
  protocol = local.any_protocol 
  cidr_blocks = local.all_ips
}

data "aws_vpc" "default" {
   default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

data "terraform_remote_state" "db" {
  backend = "s3"
  config = {
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "us-east-2"
  }
}

locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}

# data "template_file" "user_data" {
#   template = file("${path.module}/user-data.sh")

#   vars={
#     server_port = var.server_port
#     db_address = data.terraform_remote_state.db.outputs.address 
#     db_port = data.terraform_remote_state.db.outputs.port
#   }
# }
