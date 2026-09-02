# ADR-002: 클러스터 내 PostgreSQL 대신 관리형 RDS 사용
resource "aws_security_group" "rds" {
  name_prefix = "${var.project}-rds-"
  description = "Allow PostgreSQL from EKS nodes only"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_db_subnet_group" "this" {
  name = "${var.project}-db"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.project}-postgres"
  engine = "postgres"
  engine_version = "17" # 현재 운영 중인 솔루션의 DB와 동일 버전으로 맞춤 (경력 연속성)
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type = "gp3"

  db_name = "app"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az = false # 포트폴리오 환경: Single-AZ (ADR-002)
  skip_final_snapshot = true  # destroy/apply 반복 운영을 위해 생략
  backup_retention_period = 1
}
