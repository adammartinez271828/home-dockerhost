# freeze my images
docker image list
# copy image versions into docker-compose.yml as an extra image tag, commented out
docker pull

# dump the database
docker exec -it con_db_recipes pg_dumpall -U djangouser > backups/upgrade_backup.sql
./pg_extract.sh backups/upgrade_backup.sql djangodb >> backups/upgrade_backup_djangodb.sql

# shut down the database
docker compose down db_recipes

# move the old database
mv postgresql postgresql.bak

# update
docker compose up -d db_recipes

# load my data back
cat backups/upgrade_backup_djangodb.sql | docker exec -i con_db_recipes psql -U djangodb -d djangouser

# restart
docker compose restart db_recipes
