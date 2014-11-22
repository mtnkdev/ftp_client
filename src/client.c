#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdarg.h>
#include <netdb.h>
#include <errno.h>
#include <glib.h>
#include "socket.h"
#include "communication.h"
#include "regex.h"

//-----------------------------------------------------Main------------------------------------------------

int main(int argc, char *argv[]) {
	int val;
	//Valeurs par defaut
	char *serveur = "127.0.0.1";
	char *port = "21";
	char *fichier = NULL;
	char *user = "anonymous";
	char *passwd = NULL;
	int debug = 0;
	FILE* entree;
  
	//On recupere les variables utilis√©es dans le terminal
	while ((val = getopt(argc, argv, "dh:p:f:u:P:")) != -1) {
		switch (val) {
			case 'h':
				serveur = optarg;
			break;
			case 'p':
				port = optarg;
			break;
			case 'f':
				fichier = optarg;
			break;
			case 'u':
				user = optarg;
			break;
			case 'P':
				passwd = optarg;
			break;
			case 'd':
				debug++;
			break;
			default :
				fprintf(stderr, "L'option %c est inconnue ou mal utilisee\n", optopt);
				fprintf(stderr, "Usage %s [-h serveur] [-p port] [-f fichier] [-u user] [-P mot de passe] [-d]\n", argv[0]);
				exit(1);
		}
	}
	
	//--------------------------------------
	//Premiere connexion avec le serveur FTP
	//--------------------------------------
	// socket  (s)
	int s=-1;
	int res;
	s=connexion(s,serveur,port);

	//-------------------------------------
	// Connexion etablie avec le serveur ftp (mode passif)
	//-------------------------------------
	char buff[TAILLE_BUFF];
	res=recoieMessage(s,buff);
	if (res<0){
		fprintf(stderr,"ERR: pas de message recu (bienvenue).\n");
		return -1;
	}
	fprintf(stderr,"OK: Bienvenue\n");

	res=envoieMessage(s,"USER %s\n",user);
	if (res<0){
		perror("ERR: erreur dans le send de USER");
		return -1;
	}
	fprintf(stderr,"OK: Please specify\n");
	res=recoieMessage(s,buff);
	if (res<0) {
		fprintf(stderr,"ERR : pas de message recu (pour USER).\n");
		return -1;
	}
	res=envoieMessage(s,"PASS %s\n",passwd);
	if (res<0){
		perror("ERR: erreur dans le send de PASS");
		return -1;
	}
	fprintf(stderr,"OK: Login successful\n");
	
	res=recoieMessage(s,buff);
	if (res<0){
		fprintf(stderr,"ERR : pas de message recu (pour PASS).\n");
		return -1;
	}
	
	//------------------------------------
	//On determine quelle entree utiliser
	//-----------------------------------
	if (fichier == NULL){
		entree=stdin;
	}else {
		entree=fopen(fichier,"r");
		if (entree==NULL){
			fprintf(stderr, "ERR: On ne pas ouvrir le fichier\n");
			return -1;
		}
	}
	// -------------------------------------
	// Dialogue
	// -------------------------------------

	while (1) {
		fgets(buff, TAILLE_BUFF,entree);
		// Le dernier carractere est un retour chariot
		buff[strlen(buff)-1] = '\0';
		
		//Pour traiter la ligne avec que des 'A'
		if(buff[0]=='A') {
			do{
				fgets(buff,TAILLE_BUFF,entree);
			}
			while(buff[0]=='A');
		}
		
		//On recupere ce qui a ÈtÈ saisie au clavier ou sur le fichier avec des expressions reguliËres
		gchar ** commande=NULL;
		commande = recup_match_chaine("(recuperer)(.+)",buff);
		if (commande==NULL){
			commande = recup_match_chaine("(repertoire)(.+)",buff);
			if(commande==NULL){
				commande = recup_match_chaine("(lister)(.+)",buff);
					if(commande==NULL || commande[1]==NULL){
						commande = recup_match_chaine("(deconnecte)",buff);
						if(commande==NULL){
							commande = recup_match_chaine("(lister)",buff);
							if(commande==NULL){
								fprintf(stderr,"ERR: Usage : lister , recuperer <nom fichier> , repertoire <nom du repertoire> , deconnecter\n");
							}else{
		//----------------------------------------
		//Lister en passant un repertoire comme parametre
		//----------------------------------------
								res=envoieMessage(s,"PASV\n",passwd);
								if (res<0){
									perror("ERR: erreur dans le send pour PASV");
									return -1;
								}
								res = recoieMessage(s,buff);
								if (res<0) {
									fprintf(stderr,"ERR : pas de message recu (pour PASV).\n");
										return -1;
									}
									//Traitement des expressions rÈguliËres pour le mode passif
									//On recupere l'adresse IP et le port il faut nous connecter pour le mode passif
									int i;
									gchar **matchs_adresse=NULL;
									char * expression="(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)";
									matchs_adresse = recup_match_chaine(expression, buff);
	
									if (matchs_adresse == NULL) {
										fprintf(stderr, "La chaine %s ne correspond pas a l'expression %s\n", buff, expression);
									}
	
									char adresse_pasv[100];
									adresse_pasv[0]='\0';
									for(i=0;i<4;i++){
										strcat(adresse_pasv,matchs_adresse[i]);
										strcat(adresse_pasv,".");
									}
									adresse_pasv[strlen(adresse_pasv)-1]='\0';
									fprintf(stdout,"Adresse pour le pasv: %s\n",adresse_pasv);
	
									char port_pasv[12];
									int port1;
									sscanf(matchs_adresse[4],"%d",&port1);
									int port2;
									sscanf(matchs_adresse[5],"%d",&port2);
									int port_pas=port1*256+port2;
									sprintf(port_pasv,"%d",port_pas);
	
									fprintf(stdout,"Port pour le pasv: %s\n\n",port_pasv);
									
									// socket  (s2)
									int s2=-1;
									s2=connexion(s2,adresse_pasv,port_pasv);
									
									fprintf(stderr,"OK: Entering Passive\n");
									res=envoieMessage(s,"LIST\n");
									if(res<0){
										perror("ERR: On ne peut lister le contenu du repertoire");
										return -1;
									}
									res=recoieMessage(s,buff);
									if (res<0) {
										fprintf(stderr,"ERR : pas de message recu (pour derniere commmande)\n");
										break;
									}
									fprintf(stderr,"OK: Here comes\n");
							
									do{
									res=RecoieDonnees(STDIN_FILENO,s2);
									}
									while(res!=0);
										res = recoieMessage(s,buff);
										if (res<0) {
										fprintf(stderr,"ERR : pas de message recu (pour PASV).\n");
										return -1;
									}
									if (close(s2)< 0) {
										perror("ERR: Probleme √†  la fermeture de la socket");
									}
									while (matchs_adresse[i] != NULL) {
										g_free(matchs_adresse[i]);
										i++;
									}		
									g_free(matchs_adresse);
									g_free(commande);
									fprintf(stderr,"OK: Directory send\n");
								}
			//----------------------------------------
			//Deconnexion
			//----------------------------------------
						}else{ //Dans ou on a voulu se deconnecter
							res=envoieMessage(s,"QUIT\n");
							if (res<0){
								perror("ERR: On ne peut pas se deconnecter");
								return -1;
							}
							res=recoieMessage(s,buff);
							if (res<0) {
								fprintf(stderr,"ERR : pas de message recu (pour derniere commmande)\n");
								break;
							}
							fprintf(stderr,"OK: Goodbye\n");
							break;
							g_free(commande);
						}
						
						
			//----------------------------------------
			//Lister le contenu du repertoire corrant repertoire
			//----------------------------------------
						}else{ //Dans le cas ou on a voulu lister le contenu du repertoire courrant
							fprintf(stdout,"On veut lister le contenu\n");
						
							res=envoieMessage(s,"PASV\n",passwd);
							if (res<0){
								perror("ERR: erreur dans le send pour PASV");
								return -1;
							}
							res = recoieMessage(s,buff);
							if (res<0) {
								fprintf(stderr,"ERR : pas de message recu (pour PASV).\n");
								return -1;
							}
							//Traitement des expressions rÈguliËres pour le mode passif
							//On recupere l'adresse IP et le port il faut nous connecter pour le mode passif
							int i;
							gchar **matchs_adresse=NULL;
							char * expression="(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)";
	
							matchs_adresse = recup_match_chaine(expression, buff);
	
							if (matchs_adresse == NULL) {
								fprintf(stderr, "La chaine %s ne correspond pas a l'expression %s\n", buff, expression);
							} 
	
							char adresse_pasv[100];
							adresse_pasv[0]='\0';
							for(i=0;i<4;i++){
								strcat(adresse_pasv,matchs_adresse[i]);
								strcat(adresse_pasv,".");
							}
							adresse_pasv[strlen(adresse_pasv)-1]='\0';
							fprintf(stdout,"Adresse pour le pasv: %s\n",adresse_pasv);
	
							char port_pasv[12];
							int port1;
							sscanf(matchs_adresse[4],"%d",&port1);
							int port2;
							sscanf(matchs_adresse[5],"%d",&port2);
							int port_pas=port1*256+port2;
							sprintf(port_pasv,"%d",port_pas);
	
							fprintf(stdout,"Port pour le pasv: %s\n\n",port_pasv);

							// socket  (s2)
							int s2=-1;
							s2=connexion(s2,adresse_pasv,port_pasv);
							
							res=envoieMessage(s,"CWD%s\n",commande[1]);
							if(res<0){
								perror("ERR: On ne peut pas changer de repertoire");
								return -1;
							}
							res=recoieMessage(s,buff);
							if (res<0) {
								fprintf(stderr,"ERR : pas de message recu (pour derniere commmande)\n");
								break;
							}
							fprintf(stderr,"OK: Entering Passive\n");
							res=envoieMessage(s,"LIST\n");
							if(res<0){
								perror("ERR: On ne peut changer de repertoire");
								return -1;
							}
							res=recoieMessage(s,buff);
							if (res<0) {
								fprintf(stderr,"ERR : pas de message recu (pour derniere commmande)\n");
								break;
							}
							fprintf(stderr,"OK: Here comes\n");
							
							do{
								res=RecoieDonnees(STDIN_FILENO,s2);
							}
							while(res!=0);
							res = recoieMessage(s,buff);
							if (res<0) {
								fprintf(stderr,"ERR : pas de message recu (pour PASV).\n");
								return -1;
							}
							if (close(s2)< 0) {
								perror("ERR: Probleme √†  la fermeture de la socket");
							}
							while (matchs_adresse[i] != NULL) {
								g_free(matchs_adresse[i]);
								i++;
							}		
							g_free(matchs_adresse);
							g_free(commande);
							fprintf(stderr,"OK: Directory send\n");
						}
					
		//---------------------------------------
		//Changement de repertoire
		//---------------------------------------
				} else { //Dans le cas ou on veut changer de repertoire
					res=envoieMessage(s,"CWD%s\n",commande[1]);
					if(res<0){
						perror("ERR: On ne peut changer de repertoire");
						return -1;
					}
					res=recoieMessage(s,buff);
					if (res<0) {
						fprintf(stderr,"ERR : pas de message recu (pour derniere commmande)\n");
						break;
					}
					
					if(buff[0]=='2')
						fprintf(stderr,"OK: Directory successfully\n");
					else if(buff[0]=='5')
						fprintf(stderr,"ERR: Failed to\n");
					g_free(commande);
				}
		//---------------------------------------
		//Dans le cas o˘ on veut rÈcuperer un fichier	
		//---------------------------------------
			} else { 
			
				res=envoieMessage(s,"PASV\n",passwd);
				if (res<0){
					perror("ERR: erreur dans le send pour PASV");
					return -1;
				}
				res = recoieMessage(s,buff);
				if (res<0) {
					fprintf(stderr,"ERR : pas de message recu (pour PASV).\n");
					return -1;
				}
				fprintf(stderr,"OK: Entering passive\n");
				//Traitement des expressions rÈguliËres pour le mode passif
				//On recupere l'adresse IP et le port il faut nous connecter pour le mode passif
				int i;
				gchar **matchs_adresse=NULL;
				char * expression="(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)\\,(\\d+)";

				matchs_adresse = recup_match_chaine(expression, buff);	
				if (matchs_adresse == NULL) {
					fprintf(stderr, "La chaine %s ne correspond pas a l'expression %s\n", buff, expression);
				} 
	
				char adresse_pasv[100];
				adresse_pasv[0]='\0';
				for(i=0;i<4;i++){
					strcat(adresse_pasv,matchs_adresse[i]);
					strcat(adresse_pasv,".");
				}
				adresse_pasv[strlen(adresse_pasv)-1]='\0';
				fprintf(stdout,"Adresse pour le pasv: %s\n",adresse_pasv);

				char port_pasv[12];
				int port1;
				sscanf(matchs_adresse[4],"%d",&port1);
				int port2;
				sscanf(matchs_adresse[5],"%d",&port2);
				int port_pas=port1*256+port2;
				sprintf(port_pasv,"%d",port_pas);
			
				fprintf(stdout,"Port pour le pasv: %s\n\n",port_pasv);
				
				char leFichier[100];
				char* leFic=strrchr(commande[1],'/');
				leFichier[0]='\0';
				if(leFic!=NULL){
					for(i=1;i<strlen(leFic);i++)
						leFichier[i-1]=leFic[i];
					leFichier[strlen(leFic)-1]='\0';
				}else{
					for(i=1;i<strlen(commande[1]);i++)
						leFichier[i-1]=commande[1][i];
					leFichier[strlen(commande[1])-1]='\0';
				}
				fprintf(stdout,"On veut recuperer le fichier%s\n",commande[1]);
				fprintf(stdout,"Le nom du fichier a ouvrir: %s\n",leFichier);
				
				int fic1;
				mode_t mode = S_IRUSR | S_IWUSR;
				fic1=open(leFichier, O_WRONLY | O_CREAT | O_TRUNC ,mode);
				//Gerer les erreurs
				if (fic1==-1){
					fprintf(stderr, "ERR: On ne pas ouvrir le fichier\n");
					return -1;
				}
				
				// socket  (s2)			
				int s2=-1;
				s2=connexion(s2,adresse_pasv,port_pasv);

				//Dialogue pour rÈcuperer le fichier et Ècriture sur le fichier
				
				res=envoieMessage(s,"RETR%s\n",commande[1]);
				if(res<0){
					perror("ERR: On ne peut changer de repertoire");
					return -1;
				}
				res=recoieMessage(s,buff);
				if (res<0) {
					fprintf(stderr,"ERR : pas de message recu (pour derniere commmande)\n");
					break;
				}
				if(buff[0]=='1'){
					fprintf(stderr,"OK: Opening\n");
				
					do{
						fprintf(stdout,"On recoit\n");
						res=RecoieDonnees(fic1,s2);
					}
					while(res!=0);
				
					res = recoieMessage(s,buff);
					if (res<0) {
						fprintf(stderr,"ERR : pas de message recu apres recevoir le fichier.\n");
						return -1;
					}
					g_free(commande);
			
					fprintf(stderr,"OK: File send\n");
					//On ferme le fichier apres l'ecriture
					close(fic1);
			
				}else {
					fprintf(stderr,"ERR: Failed\n");
					res=unlink(leFichier);
					if (res ==0){
						fprintf(stdout,"Fichier n'a pas pu Ítre rÈcuperÈ on l'Èlimine\n");
					}
				}
				
				if (close(s2)< 0) {
					perror("ERR: Probleme a la fermeture de la socket");
				}
				i=0;
				while (matchs_adresse[i] != NULL) {
					g_free(matchs_adresse[i]);
					i++;
				}
				g_free(matchs_adresse);
				
			}

		}
		if(fichier!=NULL){
			fclose(entree);
		}
	
	//---------------------------------------
	// Fermeture de la connexion
	//---------------------------------------
	
	if (close(s)< 0) {
		perror("ERR: Probleme a la fermeture de la socket");
	}
	fprintf(stdout, "Bye\n");
	return 0;
}
