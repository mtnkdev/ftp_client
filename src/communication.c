#include <sys/types.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdarg.h>
#include <netdb.h>
#include <errno.h>

#include "communication.h"


//----------------------------------------- Communication avec le serveur -------------------------------------------------

//envoieMessage envoie un message au serveur ftp
int envoieMessage (int s, char *format, ...) {
	int i;
	int res;

	va_list liste_arg;
	va_start (liste_arg, format);

	// on calcule la taille du message
	int taille = vsnprintf (NULL, 0 , format , liste_arg) ;
	va_end (liste_arg) ;

	// un tableau un peu plus grand pour le \0
	char chaine [taille+1];

	va_start (liste_arg , format ) ;
	vsnprintf(chaine, taille +1, format , liste_arg) ;
	va_end (liste_arg) ;

	// fprintf (stderr ,"Envoie %s \n" , chaine) ;

	i = 0;
	while ( i < taille ) {
		res = send ( s , chaine+i , taille-i , MSG_NOSIGNAL) ;
	
		if (res <=0){
			fprintf( stderr , " error : write %s car %s\n" , chaine , strerror(errno) ) ;
			return -1;
		}
		i += res ;
	}
	return i ;
}


//recoieMessage, recoit un message du serveur ftp
int recoieMessage (int s, char* buff) {
	int res;
	res = recv(s , buff , TAILLE_BUFF , MSG_NOSIGNAL);
	if (res>0){
		buff[res]='\0';
		fprintf(stdout, "%s\n", buff);
	}
	return res;
}

//------------------------------------------------Recevoir des donnees--------------------------------------

int RecoieDonnees (int fd, int s) {
	char buff [TAILLE_BUFF];
	int res , res2 ;
	int nb_recu = 0;
	while (1) {

		res = recv (s,buff,TAILLE_BUFF,0);

		if (res< 0) {
			perror (" Probleme a  la lecture du fichier." );
			return -1;
		}
		if (res == 0 ) { // Le fichier est termine
			break ;
		}
		nb_recu+=res;
		//fprintf(stderr, "Recu %d oct total: %d oct \n" ,res, nb_recu) ;

		res2= write (fd,buff,res) ;
		if(res != res2) {
			perror ( " Probleme a l'ecriture du fichier " ) ;
		return -1;
		}
	}	
	return nb_recu ;
}
